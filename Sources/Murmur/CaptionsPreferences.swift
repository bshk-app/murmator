import AppKit
import MurmurCaptions
import Observation

/// Relative to one display's visible area, so a resolution/Dock change does not
/// strand the panel off screen. Different displays keep separate placements.
struct CaptionsPlacement: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(frame: NSRect, visible: NSRect) {
        x = (frame.minX - visible.minX) / visible.width
        y = (frame.minY - visible.minY) / visible.height
        width = frame.width / visible.width
        height = frame.height / visible.height
    }

    func frame(in visible: NSRect) -> NSRect {
        NSRect(x: visible.minX + x * visible.width, y: visible.minY + y * visible.height,
               width: width * visible.width, height: height * visible.height)
    }

    static func fitted(_ frame: NSRect, visible: NSRect, minimum: CGSize) -> NSRect {
        let width = min(visible.width, max(ceil(minimum.width), frame.width.rounded()))
        let height = min(visible.height, max(ceil(minimum.height), frame.height.rounded()))
        return NSRect(x: min(max(frame.minX.rounded(), visible.minX), visible.maxX - width),
                      y: min(max(frame.minY.rounded(), visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}

@MainActor
@Observable
final class CaptionsPreferences {
    static let appearanceKey = "murmur.captionsAppearance.v1"
    static let placementsKey = "murmur.captionsPlacements.v1"
    var appearance: CaptionsAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: Self.appearanceKey) }
            onChange?()
        }
    }
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var placements: [String: CaptionsPlacement]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.data(forKey: Self.appearanceKey)
            .flatMap { try? JSONDecoder().decode(CaptionsAppearance.self, from: $0) } ?? CaptionsAppearance()
        placements = defaults.data(forKey: Self.placementsKey)
            .flatMap { try? JSONDecoder().decode([String: CaptionsPlacement].self, from: $0) } ?? [:]
    }

    func placement(for display: String) -> CaptionsPlacement? { placements[display] }

    func save(frame: NSRect, on display: String, visible: NSRect) {
        placements[display] = CaptionsPlacement(frame: frame, visible: visible)
        persistPlacements()
    }

    func resetPlacement(for display: String) {
        placements.removeValue(forKey: display)
        persistPlacements()
        onChange?()
    }

    private func persistPlacements() {
        if let data = try? JSONEncoder().encode(placements) { defaults.set(data, forKey: Self.placementsKey) }
    }
}
