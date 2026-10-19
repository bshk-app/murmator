import AVFoundation
import CryptoKit
import Foundation

// Measure labelled 16 kHz mono recordings; do not record or change settings.
let usage = "Usage: swift scripts/measure-batch-silence.swift --microphone NAME --noise FILE [--noise FILE ...] --quiet-speech FILE [--quiet-speech FILE ...]"

func failure(_ text: String) -> NSError {
    NSError(domain: "Murmur.BatchSilenceCalibration", code: 1,
            userInfo: [NSLocalizedDescriptionKey: text])
}

func measure(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == 16_000,
          file.processingFormat.channelCount == 1, file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)) else {
        throw failure("\(path): an actual 16 kHz mono capture is required")
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { throw failure("\(path): no Float PCM") }
    let count = Int(buffer.frameLength)
    var peak = 0.0
    for start in stride(from: 0, to: count, by: 512) {
        let end = min(start + 512, count)
        var energy = 0.0
        for index in start..<end { energy += Double(channel[index]) * Double(channel[index]) }
        guard energy.isFinite else { throw failure("\(path): non-finite PCM") }
        peak = max(peak, (energy / Double(end - start)).squareRoot())
    }
    let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    return ["path": url.path, "sha256": hash, "samples": count,
            "seconds": Double(count) / 16_000, "peak_rms_512": peak]
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var values: [String: [String]] = [:]
    var index = 0
    while index < arguments.count {
        let option = arguments[index]
        guard ["--microphone", "--noise", "--quiet-speech"].contains(option),
              index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw failure(usage)
        }
        values[option, default: []].append(arguments[index + 1])
        index += 2
    }
    guard let microphones = values["--microphone"], microphones.count == 1,
          let noisePaths = values["--noise"], !noisePaths.isEmpty,
          let speechPaths = values["--quiet-speech"], !speechPaths.isEmpty else { throw failure(usage) }
    let noise = try noisePaths.map(measure)
    let speech = try speechPaths.map(measure)
    let noisePeak = noise.map { $0["peak_rms_512"] as! Double }.max()!
    let speechPeak = speech.map { $0["peak_rms_512"] as! Double }.min()!
    // Smallest representable Float floor above every measured noise peak.
    // Refuse a floor that overlaps the quietest labelled speech recording.
    let candidate = Float(noisePeak).nextUp
    let separated = candidate.isFinite && Double(candidate) > noisePeak && Double(candidate) < speechPeak
    let report: [String: Any] = [
        "microphone": microphones[0], "sample_rate": 16_000, "frame_samples": 512,
        "noise_recordings": noise, "quiet_speech_recordings": speech,
        "maximum_noise_peak_rms": noisePeak, "minimum_quiet_speech_peak_rms": speechPeak,
        "candidate_silence_floor_rms": separated ? Double(candidate) as Any : NSNull(),
        "capture_peak_rms_included": false,
        "note": "File measurements only. Confirm the microphone and capture peak RMS before enabling a nonzero production floor. No settings were changed.",
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
