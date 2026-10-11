#if os(macOS)
  import Foundation
  import HuggingFace

  /// One immutable 16.9 MB archive, verified before every load. No Python checkpoint
  /// or Needle runtime is downloaded. Installation is serialized within this app.
  public enum WhistleAssets {
    public static let repository = "Cactus-Compute/whistle"
    public static let revision = "ca5287601bef25af26dcf2e1b2bdc0843a7c19e5"
    public static let sha256 = "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    public static let bytes = 16_919_407
    public static var directory: URL {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MurMur/Whistle/" + revision, isDirectory: true)
    }
    static let asset = PinnedAsset(path: "whistle.cact", bytes: bytes, sha256: sha256)
    public static func prepare(
      onProgress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
      try await WhistleAssetInstaller.shared.prepare(onProgress: onProgress)
    }
  }

  private actor WhistleAssetInstaller {
    static let shared = WhistleAssetInstaller()
    // Actor reentrancy must not start a second installer while a download awaits.
    private var pending: Task<URL, Error>?
    func prepare(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws -> URL
    {
      if let pending { return try await pending.value }
      let task = Task { try await install(onProgress: onProgress) }
      pending = task
      defer { pending = nil }
      return try await withTaskCancellationHandler(
        operation: {
          let url = try await task.value
          try Task.checkCancellation()
          return url
        }, onCancel: { task.cancel() })
    }
    private func install(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws
      -> URL
    {
      let root = WhistleAssets.directory
      let destination = root.appendingPathComponent(WhistleAssets.asset.path)
      do {
        try WhistleAssets.asset.verify(at: destination)
        return destination
      } catch is CancellationError { throw CancellationError() } catch {}
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let staging = root.appendingPathComponent(".\(UUID().uuidString).download")
      defer { try? FileManager.default.removeItem(at: staging) }
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 120
      configuration.timeoutIntervalForResource = 600
      let transport = URLSession(configuration: configuration)
      defer { transport.finishTasksAndInvalidate() }
      let progress = Progress(totalUnitCount: Int64(WhistleAssets.bytes))
      await onProgress(progress)
      let client = HubClient(session: transport, cache: nil)
      guard let repo = Repo.ID(rawValue: WhistleAssets.repository) else { throw URLError(.badURL) }
      _ = try await client.downloadFile(
        at: WhistleAssets.asset.path, from: repo, to: staging,
        revision: WhistleAssets.revision, progress: progress, transport: .lfs)
      try Task.checkCancellation()
      try WhistleAssets.asset.install(staging, in: root)
      return destination
    }
  }
#endif
