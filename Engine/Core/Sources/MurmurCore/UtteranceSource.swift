import Foundation

/// Optional provenance retained while editing a completed transcript. Capture
/// orchestration belongs to its own feature, not the transcript editor.
public enum ConversationSource: String, Codable, CaseIterable, Sendable {
    case phone, watch, headset
    public var title: String {
        switch self { case .phone: return "iPhone"; case .watch: return "Apple Watch"; case .headset: return "Headset" }
    }
}
