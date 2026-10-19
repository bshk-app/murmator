import Foundation

public struct RecordedAudio: Codable, Hashable, Sendable {
    public let recordingID: UUID
    public let filename: String
    public let isMicrophoneRecording: Bool?
    public init(recordingID: UUID = UUID(), filename: String = "original.wav", isMicrophoneRecording: Bool? = true) {
        self.recordingID = recordingID; self.filename = filename; self.isMicrophoneRecording = isMicrophoneRecording
    }
    public func url(in root: URL) throws -> URL {
        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent, filename != ".", filename != ".." else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return root.appendingPathComponent(recordingID.uuidString, isDirectory: true).appendingPathComponent(filename)
    }
    public func capturedDuration(in root: URL) -> Double? {
        guard isMicrophoneRecording == true, let url = try? url(in: root),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.uint64Value >= 44 else { return nil }
        return Double((size.uint64Value - 44) / 2) / 16_000
    }
}

/// 16 kHz mono PCM is written before recognition consumes the audio. The WAV
/// header is checkpointed on every append, so a killed app leaves playable audio.
public final class PCMRecordingWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var samples: UInt64 = 0
    private var synchronizedSamples: UInt64 = 0
    public init(url: URL, sampleRate: Int = 16_000) throws {
        guard (8_000...192_000).contains(sampleRate) else { throw CocoaError(.fileWriteInvalidFileName) }
        self.url = url; self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try Self.header(bytes: 0, sampleRate: sampleRate).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        handle = try FileHandle(forUpdating: url)
    }
    public var sampleCount: UInt64 { lock.lock(); defer { lock.unlock() }; return samples }
    public func append(_ audio: [Float]) throws {
        guard !audio.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let bytes = (samples + UInt64(audio.count)) * 2
        guard bytes <= UInt64(UInt32.max - 36) else { throw CocoaError(.fileWriteOutOfSpace) }
        var pcm = Data(capacity: audio.count * 2)
        for sample in audio {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            var encoded = Int16((value * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &encoded) { pcm.append(contentsOf: $0) }
        }
        try handle.seek(toOffset: 44 + samples * 2)
        try handle.write(contentsOf: pcm)
        samples += UInt64(audio.count)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(bytes: UInt32(bytes), sampleRate: sampleRate))
        if samples - synchronizedSamples >= UInt64(sampleRate) {
            try handle.synchronize(); synchronizedSamples = samples
        }
    }
    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        try handle.synchronize(); try handle.close(); self.handle = nil
    }
    deinit { try? handle?.close() }
    /// Salvage a last append even if the process stopped between data and header writes.
    @discardableResult public static func repair(_ url: URL) throws -> Double {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 44, size - 44 <= UInt64(UInt32.max - 36) else { throw CocoaError(.fileReadCorruptFile) }
        let count = (size - 44) / 2 * 2
        try handle.seek(toOffset: 0)
        guard let existing = try handle.read(upToCount: 44), existing.count == 44,
              existing.prefix(4) == Data("RIFF".utf8), existing[8..<12] == Data("WAVE".utf8),
              existing[12..<16] == Data("fmt ".utf8), existing[20..<24] == Data([1, 0, 1, 0]),
              existing[34..<36] == Data([16, 0]),
              existing[36..<40] == Data("data".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let rate = existing[24..<28].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard (8_000...192_000).contains(rate) else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header(bytes: UInt32(count), sampleRate: rate)); try handle.synchronize()
        return Double(count) / Double(rate * 2)
    }
    private static func header(bytes: UInt32, sampleRate: Int) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); integer(bytes + 36); ascii("WAVEfmt "); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2)); integer(UInt16(2)); integer(UInt16(16)); ascii("data"); integer(bytes)
        return data
    }
}

/// Capture owns this sink; recognition may fall behind without dropping the recording.
public final class RecordingAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: PCMRecordingWriter?
    public init() {}
    public func begin(url: URL?) throws {
        lock.lock(); defer { lock.unlock() }
        try writer?.finish(); writer = nil
        if let url { writer = try PCMRecordingWriter(url: url) }
    }
    public func append(_ samples: [Float]) throws {
        lock.lock(); defer { lock.unlock() }; try writer?.append(samples)
    }
    public func finish() throws {
        lock.lock(); defer { lock.unlock() }; try writer?.finish(); writer = nil
    }
}
