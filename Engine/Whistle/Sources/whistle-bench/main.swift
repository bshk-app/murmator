import CryptoKit
import Darwin
import Foundation
import WhistleCPU

struct Preview: Codable {
  let audioSeconds: Double
  let completedSeconds: Double
  let result: DecoderResult
}

actor Worker {
  let recognizer: WhistleRecognizer
  var utterance: WhistleUtterance
  init(url: URL) throws {
    let loaded = try WhistleRecognizer(weightsURL: url)
    recognizer = loaded
    utterance = loaded.makeUtterance()
  }
  func append(_ audio: [Float], allowPreview: Bool) throws -> DecoderResult? {
    try utterance.append(audio, allowPreview: allowPreview)
  }
  func finish() throws -> (DecoderResult, WhistleCompute, Int) {
    let result = try utterance.finish()
    return (result, utterance.compute, utterance.encoderFrames)
  }
}

final class Backlog: @unchecked Sendable {
  let lock = NSLock()
  var pending = 0
  var peak = 0
  func add(_ count: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    guard pending + count <= 160_000 else { throw WhistleRecognitionError.windowLimit }
    pending += count
    peak = max(peak, pending)
  }
  func release(_ count: Int) {
    lock.lock()
    defer { lock.unlock() }
    pending -= count
  }
  func maximum() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return peak
  }
  func current() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return pending
  }
}

@main struct Benchmark {
  static func main() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 6 || args.count == 8 else {
      throw DecoderError.invalid(
        "whistle-bench --weights FILE --pcm F32 --output JSON [--paced true|false]")
    }
    var options: [String: String] = [:]
    for i in stride(from: 0, to: args.count, by: 2) {
      guard ["--weights", "--pcm", "--output", "--paced"].contains(args[i]), options[args[i]] == nil
      else {
        throw DecoderError.invalid("unknown/duplicate option")
      }
      options[args[i]] = args[i + 1]
    }
    guard let weights = options["--weights"], let pcm = options["--pcm"],
      let output = options["--output"],
      options["--paced"] == nil || ["true", "false"].contains(options["--paced"]!)
    else { throw DecoderError.invalid("missing/invalid option") }
    let paced = options["--paced"] != "false"
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: pcm))
    let data = try file.read(upToCount: WhistleRecognizer.maximumSamples * 4 + 1) ?? Data()
    try file.close()
    guard !data.isEmpty, data.count % 4 == 0, data.count <= WhistleRecognizer.maximumSamples * 4
    else {
      throw WhistleRecognitionError.invalidPCM
    }
    let audio = data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
    let loadStarted = ProcessInfo.processInfo.systemUptime
    let worker = try Worker(url: URL(fileURLWithPath: weights))
    let started = ProcessInfo.processInfo.systemUptime
    let backlog = Backlog()
    let (stream, input) = AsyncThrowingStream<[Float], Error>.makeStream()
    let producer = Task.detached {
      var lag = 0.0
      defer { input.finish() }
      for offset in stride(from: 0, to: audio.count, by: 1536) {
        let end = min(offset + 1536, audio.count)
        let deadline = started + Double(end) / 16_000
        if paced {
          let delay = deadline - ProcessInfo.processInfo.systemUptime
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
          lag = max(lag, ProcessInfo.processInfo.systemUptime - deadline)
        }
        try Task.checkCancellation()
        if paced { try backlog.add(end - offset) }
        input.yield(Array(audio[offset..<end]))
      }
      return lag
    }
    var previews: [Preview] = []
    var consumed = 0
    do {
      for try await chunk in stream {
        consumed += chunk.count
        if let result = try await worker.append(
          chunk, allowPreview: !paced || backlog.current() <= 6144)
        {
          previews.append(
            .init(
              audioSeconds: Double(consumed) / 16_000,
              completedSeconds: ProcessInfo.processInfo.systemUptime - started, result: result))
        }
        if paced { backlog.release(chunk.count) }
      }
      let lag = try await producer.value
      let finalStarted = ProcessInfo.processInfo.systemUptime
      let (result, compute, frames) = try await worker.finish()
      let ended = ProcessInfo.processInfo.systemUptime
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      struct Report: Encodable {
        let paced: Bool
        let pcmSHA256: String
        let audioSeconds: Double
        let loadSeconds: Double
        let wallSeconds: Double
        let firstPreviewSeconds: Double?
        let finalizationSeconds: Double
        let maxInputLagSeconds: Double
        let peakQueuedAudioSeconds: Double
        let peakRSSBytes: Int
        let encoderFrames: Int
        let compute: WhistleCompute
        let previews: [Preview]
        let final: DecoderResult
      }
      let report = Report(
        paced: paced,
        pcmSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        audioSeconds: Double(audio.count) / 16_000, loadSeconds: started - loadStarted,
        wallSeconds: ended - started, firstPreviewSeconds: previews.first?.completedSeconds,
        finalizationSeconds: ended - finalStarted, maxInputLagSeconds: lag,
        peakQueuedAudioSeconds: Double(backlog.maximum()) / 16_000, peakRSSBytes: usage.ru_maxrss,
        encoderFrames: frames, compute: compute, previews: previews, final: result)
      try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
      print(output)
    } catch {
      producer.cancel()
      input.finish()
      _ = try? await producer.value
      throw error
    }
  }
}
