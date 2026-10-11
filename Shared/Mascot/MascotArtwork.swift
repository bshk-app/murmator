import SwiftUI

enum MascotExpression {
    case happy, listening, thinking, celebrating, sad, blinking

    /// Six poses share one costume sheet, ordered left to right, top to bottom.
    var spriteIndex: Int {
        switch self {
        case .happy: 0
        case .listening: 1
        case .thinking: 2
        case .celebrating: 3
        case .sad: 4
        case .blinking: 5
        }
    }
}

/// Costume variations retain the original mascot's shaded illustration style.
struct MascotArtwork: View {
    let style: MascotStyle
    var expression: MascotExpression = .happy
    var hasMoustache = true

    var body: some View {
        GeometryReader { geometry in
            let classic = style == .classic && hasMoustache
            let height = min(geometry.size.height, geometry.size.width * (classic ? 208.0 / 192.0 : 1))
            let width = height * (classic ? 192.0 / 208.0 : 1)
            let pose = expression.spriteIndex
            let column = classic ? (expression == .blinking ? 1 : 0) : pose % 3
            let row = classic ? classicRow : pose / 3
            Image(style.artworkName(hasMoustache: hasMoustache))
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(width: width * (classic ? 8 : 3), height: height * (classic ? 11 : 2), alignment: .topLeading)
                .offset(x: -CGFloat(column) * width, y: -CGFloat(row) * height)
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transaction { $0.animation = nil }
        }
        .accessibilityHidden(true)
    }

    private var classicRow: Int {
        switch expression {
        case .happy, .blinking: 0
        case .listening: 6
        case .thinking: 7
        case .celebrating: 4
        case .sad: 5
        }
    }
}
