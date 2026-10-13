import AppKit

public struct CaptionsColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    public init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent
    }
}

/// How captions look. A value: the app decides where it is stored.
public struct CaptionsAppearance: Codable, Equatable, Sendable {
    public var fontFamily = ""
    public var automaticFontSize = true
    public var fontSize = 25.0
    public var textColor = CaptionsColor(.white)
    public var translationColor = CaptionsColor(NSColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 1))
    public var backgroundColor = CaptionsColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1))
    public var backgroundOpacity = 1.0

    public init() {}

    public func pointSize(screenHeight: CGFloat) -> CGFloat {
        automaticFontSize ? min(max((screenHeight / 44).rounded(), 14), 48) : min(max(fontSize, 14), 72)
    }

    public static func font(size: CGFloat, family: String = "") -> NSFont {
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return font }
        return .systemFont(ofSize: size, weight: .medium)
    }
}
