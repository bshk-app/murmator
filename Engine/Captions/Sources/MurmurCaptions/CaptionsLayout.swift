import AppKit

/// Three lines per language, using smaller type to leave the presentation visible.
public struct CaptionsLayout: Equatable, Sendable {
    public let fontSize: CGFloat
    public let translationFontSize: CGFloat
    public let fontFamily: String
    public let bandWidth: CGFloat
    public let transcriptLines: Int
    public let translationLines: Int
    public let padding: CGFloat
    public let bottomInset: CGFloat
    private let customHeight: CGFloat?

    /// - Parameters:
    ///   - screen: the display the captions are read on; sets the type size.
    ///   - size: the band's own size when the user (or the host app) chose one;
    ///     extra height becomes extra lines.
    public init(screen: CGSize, translating: Bool, appearance: CaptionsAppearance = CaptionsAppearance(), size: CGSize? = nil) {
        fontSize = appearance.pointSize(screenHeight: screen.height)
        translationFontSize = (fontSize * 0.92).rounded()
        fontFamily = appearance.fontFamily
        bandWidth = size?.width ?? (screen.width * 0.8).rounded()
        padding = max(6, (fontSize * 0.25).rounded())
        bottomInset = (screen.height * 0.05).rounded()
        customHeight = size?.height
        let gap = (padding * 0.6).rounded()
        let original = Self.trackHeight(lines: 3, size: fontSize, family: fontFamily)
        let translated = translating ? Self.trackHeight(lines: 3, size: translationFontSize, family: fontFamily) : 0
        let available = max(original + translated, (size?.height ?? 0) - padding * 2 - (translating ? gap : 0))
        let share = translating ? original / (original + translated) : 1
        func lines(height: CGFloat, font: CGFloat) -> Int {
            let spacing = Self.lineSpacing(font)
            let line = Self.trackHeight(lines: 1, size: font, family: appearance.fontFamily)
            return max(3, Int((height + spacing) / (line + spacing)))
        }
        transcriptLines = lines(height: available * share, font: fontSize)
        translationLines = translating ? lines(height: available * (1 - share), font: translationFontSize) : 0
    }

    public var trackGap: CGFloat { (padding * 0.6).rounded() }
    public static func lineSpacing(_ size: CGFloat) -> CGFloat { (size * 0.12).rounded() }

    public static func trackHeight(lines: Int, size: CGFloat, family: String = "") -> CGFloat {
        guard lines > 0 else { return 0 }
        let font = CaptionsAppearance.font(size: size, family: family)
        let line = ceil(font.ascender - font.descender + font.leading)
        return CGFloat(lines) * line + CGFloat(lines - 1) * lineSpacing(size)
    }

    public var minimumSize: CGSize {
        var height = padding * 2 + Self.trackHeight(lines: 3, size: fontSize, family: fontFamily)
        if translationLines > 0 {
            height += trackGap + Self.trackHeight(lines: 3, size: translationFontSize, family: fontFamily)
        }
        return CGSize(width: 320, height: ceil(height))
    }

    public var bandSize: CGSize {
        CGSize(width: bandWidth, height: max(minimumSize.height, customHeight ?? 0))
    }
}
