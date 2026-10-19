import Foundation

/// The Bergamot packs are too large for the repository. Point
/// `MURMUR_BERGAMOT_MODELS` at a directory of them, e.g.
/// /Volumes/DATA/bergamot-arm64/models, to run the tests that load one.
let bergamotModels = ProcessInfo.processInfo.environment["MURMUR_BERGAMOT_MODELS"].map { URL(fileURLWithPath: $0) }
