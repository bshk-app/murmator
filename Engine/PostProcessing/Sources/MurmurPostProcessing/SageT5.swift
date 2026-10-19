import Foundation
import MLX
import MLXFast

enum SageT5Error: Error { case inputTooLong, generationLimit }

/// T5 encoder-decoder inference for the pinned SAGE checkpoints. The parameter
/// names follow the HF checkpoint; this avoids converting or duplicating weights.
/// Architecture reference: transformers v4.39.0 models/t5/modeling_t5.py.
struct SageT5Configuration: Decodable {
    let dimensions: Int, feedForwardDimensions: Int, headDimensions: Int, heads: Int
    let encoderLayers: Int, decoderLayers: Int, buckets: Int, maximumDistance: Int
    let epsilon: Float, decoderStart: Int, eos: Int, tiedEmbeddings: Bool
    enum CodingKeys: String, CodingKey {
        case dimensions = "d_model", feedForwardDimensions = "d_ff", headDimensions = "d_kv", heads = "num_heads"
        case encoderLayers = "num_layers", decoderLayers = "num_decoder_layers"
        case buckets = "relative_attention_num_buckets", maximumDistance = "relative_attention_max_distance"
        case epsilon = "layer_norm_epsilon", decoderStart = "decoder_start_token_id", eos = "eos_token_id"
        case tiedEmbeddings = "tie_word_embeddings"
    }
}

final class SageT5 {
    struct Cache { var keys: MLXArray?; var values: MLXArray? }
    let configuration: SageT5Configuration
    private let weights: [String: MLXArray]
    init(configuration: SageT5Configuration, weights: [String: MLXArray]) throws {
        self.configuration = configuration; self.weights = weights
        let c = configuration
        guard c.dimensions > 0, c.heads > 0, c.headDimensions > 0,
              c.encoderLayers > 0, c.decoderLayers > 0, c.buckets >= 4,
              c.maximumDistance > c.buckets else { throw CocoaError(.fileReadCorruptFile) }
        var required = ["shared.weight", "encoder.final_layer_norm.weight", "decoder.final_layer_norm.weight"]
        if !c.tiedEmbeddings { required.append("lm_head.weight") }
        for (stack, count) in [("encoder", c.encoderLayers), ("decoder", c.decoderLayers)] {
            required.append("\(stack).block.0.layer.0.SelfAttention.relative_attention_bias.weight")
            for index in 0..<count {
                let block = "\(stack).block.\(index).layer."
                for suffix in ["q", "k", "v", "o"] { required.append(block + "0.SelfAttention.\(suffix).weight") }
                required.append(block + "0.layer_norm.weight")
                let final = stack == "encoder" ? 1 : 2
                if stack == "decoder" {
                    for suffix in ["q", "k", "v", "o"] { required.append(block + "1.EncDecAttention.\(suffix).weight") }
                    required.append(block + "1.layer_norm.weight")
                }
                required.append(block + "\(final).layer_norm.weight")
                for suffix in ["wi_0", "wi_1", "wo"] { required.append(block + "\(final).DenseReluDense.\(suffix).weight") }
            }
        }
        guard required.allSatisfy({ weights[$0] != nil }), weights["shared.weight"]?.shape.last == c.dimensions else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func relativeBucket(distance: Int, bidirectional: Bool, buckets: Int, maximumDistance: Int) -> Int {
        let count = bidirectional ? buckets / 2 : buckets
        let sign = bidirectional && distance > 0 ? count : 0
        let position = bidirectional ? abs(distance) : max(0, -distance)
        let exact = count / 2
        if position < exact { return sign + position }
        let logarithmic = exact + Int(log(Double(position) / Double(exact)) /
            log(Double(maximumDistance) / Double(exact)) * Double(count - exact))
        return sign + min(count - 1, logarithmic)
    }
    private func bias(stack: String, queries: Int, keys: Int, offset: Int, bidirectional: Bool) -> MLXArray {
        let c = configuration
        let positions = (0..<queries).flatMap { query in
            (0..<keys).map { key in Int32(Self.relativeBucket(distance: key - query - offset,
                bidirectional: bidirectional, buckets: c.buckets, maximumDistance: c.maximumDistance)) }
        }
        return weights["\(stack).block.0.layer.0.SelfAttention.relative_attention_bias.weight"]!
            .take(MLXArray(positions).reshaped([queries, keys]), axis: 0)
            .transposed(2, 0, 1).reshaped([1, c.heads, queries, keys])
    }
    private func linear(_ input: MLXArray, _ key: String) -> MLXArray { matmul(input, weights[key]!.transposed()) }
    private func norm(_ input: MLXArray, _ key: String) -> MLXArray {
        MLXFast.rmsNorm(input, weight: weights[key]!, eps: configuration.epsilon)
    }
    private func attention(_ input: MLXArray, context: MLXArray?, key: String,
                           bias: MLXArray?, cache: inout Cache) -> MLXArray {
        let c = configuration
        func project(_ input: MLXArray, _ name: String) -> MLXArray {
            linear(input, key + ".\(name).weight").reshaped([1, input.dim(1), c.heads, c.headDimensions]).transposed(0, 2, 1, 3)
        }
        let queries = project(input, "q")
        let keys: MLXArray, values: MLXArray
        if context != nil, let oldKeys = cache.keys, let oldValues = cache.values {
            keys = oldKeys; values = oldValues
        } else {
            let newKeys = project(context ?? input, "k"), newValues = project(context ?? input, "v")
            if context == nil, let oldKeys = cache.keys, let oldValues = cache.values {
                keys = concatenated([oldKeys, newKeys], axis: 2)
                values = concatenated([oldValues, newValues], axis: 2)
            } else { keys = newKeys; values = newValues }
            cache.keys = keys; cache.values = values
        }
        // T5 training uses unscaled QK attention (scale 1), unlike GPT/Whisper.
        let attended = MLXFast.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: 1, mask: bias)
        return linear(attended.transposed(0, 2, 1, 3).reshaped([1, input.dim(1), c.heads * c.headDimensions]), key + ".o.weight")
    }
    private func feedForward(_ input: MLXArray, key: String) -> MLXArray {
        let gate = linear(input, key + ".wi_0.weight")
        // gelu_new, the tanh approximation used by both SAGE configurations.
        let activation = 0.5 * gate * (1 + tanh(Float(sqrt(2 / Double.pi)) * (gate + 0.044715 * gate * gate * gate)))
        return linear(activation * linear(input, key + ".wi_1.weight"), key + ".wo.weight")
    }
    func encode(_ tokens: [Int]) throws -> MLXArray {
        let c = configuration
        var hidden = weights["shared.weight"]!.take(MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]), axis: 0)
        let positionBias = bias(stack: "encoder", queries: tokens.count, keys: tokens.count, offset: 0, bidirectional: true)
        for index in 0..<c.encoderLayers {
            try Task.checkCancellation()
            let block = "encoder.block.\(index).layer."
            var cache = Cache()
            hidden = hidden + attention(norm(hidden, block + "0.layer_norm.weight"), context: nil,
                key: block + "0.SelfAttention", bias: positionBias, cache: &cache)
            hidden = hidden + feedForward(norm(hidden, block + "1.layer_norm.weight"), key: block + "1.DenseReluDense")
        }
        let output = norm(hidden, "encoder.final_layer_norm.weight")
        eval(output)
        return output
    }
    func generate(_ tokens: [Int], maximumTokens: Int) throws -> [Int] {
        guard !tokens.isEmpty, tokens.count <= 1_024 else { throw SageT5Error.inputTooLong }
        let c = configuration
        let encoded = try encode(tokens)
        var selfCaches = [Cache](repeating: Cache(), count: c.decoderLayers)
        var crossCaches = [Cache](repeating: Cache(), count: c.decoderLayers)
        var result: [Int] = [], token = c.decoderStart
        for step in 0..<maximumTokens {
            try Task.checkCancellation()
            var hidden = weights["shared.weight"]!.take(MLXArray([Int32(token)]).reshaped([1, 1]), axis: 0)
            let positionBias = bias(stack: "decoder", queries: 1, keys: step + 1, offset: step, bidirectional: false)
            for index in 0..<c.decoderLayers {
                let block = "decoder.block.\(index).layer."
                hidden = hidden + attention(norm(hidden, block + "0.layer_norm.weight"), context: nil,
                    key: block + "0.SelfAttention", bias: positionBias, cache: &selfCaches[index])
                hidden = hidden + attention(norm(hidden, block + "1.layer_norm.weight"), context: encoded,
                    key: block + "1.EncDecAttention", bias: nil, cache: &crossCaches[index])
                hidden = hidden + feedForward(norm(hidden, block + "2.layer_norm.weight"), key: block + "2.DenseReluDense")
            }
            hidden = norm(hidden, "decoder.final_layer_norm.weight")
            let logits = c.tiedEmbeddings ? matmul(hidden * Float(1 / sqrt(Double(c.dimensions))), weights["shared.weight"]!.transposed()) : linear(hidden, "lm_head.weight")
            token = argMax(logits, axis: -1).item(Int.self)
            if token == c.eos { return result }
            result.append(token)
        }
        throw SageT5Error.generationLimit
    }
}
