import Foundation
import SwiftUI

/// Stable values shared by both apps; renaming the product must not reset preferences.
enum MascotStyle: String, CaseIterable, Identifiable {
    case cat, astronaut, wizard, gardener, rockstar, pirate, robot, sleepy, classic

    static let defaultsKey = "murmur.mascotStyle"
    static let moustacheDefaultsKey = "murmur.mascotMoustache"
    static let defaultStyle: Self = .cat
    var id: String { rawValue }
    var artworkName: String { "mascot_\(rawValue)" }

    func artworkName(hasMoustache: Bool) -> String {
        hasMoustache ? artworkName : artworkName + "_no_moustache"
    }

    static func resolve(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? defaultStyle
    }

    var titleKey: String {
        switch self {
        case .cat: "Friendly cat"
        case .astronaut: "Astronaut"
        case .wizard: "Wizard"
        case .gardener: "Gardener"
        case .rockstar: "Rock star"
        case .pirate: "Pirate"
        case .robot: "Robot"
        case .sleepy: "Sleepy cat"
        case .classic: "Classic"
        }
    }

    var tint: Color {
        switch self {
        case .cat, .classic: Color(red: 0.91, green: 0.54, blue: 0.23)
        case .astronaut: Color(red: 0.22, green: 0.55, blue: 0.85)
        case .wizard: Color(red: 0.58, green: 0.43, blue: 0.82)
        case .gardener: Color(red: 0.36, green: 0.62, blue: 0.39)
        case .rockstar: Color(red: 0.85, green: 0.35, blue: 0.57)
        case .pirate: Color(red: 0.78, green: 0.31, blue: 0.26)
        case .robot: Color(red: 0.22, green: 0.62, blue: 0.64)
        case .sleepy: Color(red: 0.46, green: 0.51, blue: 0.76)
        }
    }
}

/// Static portraits keep the gallery inexpensive; only the live mascot animates.
struct MascotPortrait: View {
    let style: MascotStyle
    var expression: MascotExpression = .happy
    var hasMoustache = true

    var body: some View {
        MascotArtwork(style: style, expression: expression, hasMoustache: hasMoustache)
    }
}

struct MascotStylePicker: View {
    @AppStorage(MascotStyle.defaultsKey) private var storedStyle = MascotStyle.defaultStyle.rawValue
    @AppStorage(MascotStyle.moustacheDefaultsKey) private var hasMoustache = true
    @Environment(\.colorScheme) private var scheme
    private var selection: MascotStyle { .resolve(storedStyle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a companion. You can change it anytime.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Moustache", isOn: $hasMoustache)
                .toggleStyle(.switch)
                .accessibilityIdentifier("mascot-moustache")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(MascotStyle.allCases) { style in
                    Button { storedStyle = style.rawValue } label: {
                        VStack(spacing: 6) {
                            MascotPortrait(style: style, hasMoustache: hasMoustache)
                                .frame(width: 76, height: 76)
                            Text(LocalizedStringKey(style.titleKey))
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity)
                        .background(style.tint.opacity(selection == style ? 0.16 : 0.05), in: .rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(selection == style ? style.tint : Color.primary.opacity(0.10), lineWidth: selection == style ? 2 : 1)
                        }
                        .overlay(alignment: .topTrailing) {
                            if selection == style {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(style.tint)
                                    .background(scheme == .dark ? Color.black : Color.white, in: .circle)
                                    .padding(6)
                            }
                        }
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(Text(LocalizedStringKey(style.titleKey)))
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                    .accessibilityIdentifier("mascot-style-\(style.rawValue)")
                }
            }
            if selection == .classic {
                Text(LocalizedStringKey(hasMoustache ? "The original mascot, with its cap and moustache." : "Classic costume without a moustache."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mascot-style-picker")
    }
}

struct SelectedMascotPortrait: View {
    @AppStorage(MascotStyle.defaultsKey) private var storedStyle = MascotStyle.defaultStyle.rawValue
    @AppStorage(MascotStyle.moustacheDefaultsKey) private var hasMoustache = true

    var body: some View {
        MascotPortrait(style: .resolve(storedStyle), hasMoustache: hasMoustache)
    }
}

/// The caller owns the clock, so paused and Reduce Motion views do no animation work.
struct AnimatedMascotPortrait: View {
    let style: MascotStyle
    let expression: MascotExpression
    let elapsed: TimeInterval
    let reduceMotion: Bool
    var hasMoustache = true

    private var phase: Double { reduceMotion ? 0 : max(0, elapsed) }
    private var motion: MascotMotion {
        MascotMotion(expression: expression, elapsed: phase, reduceMotion: reduceMotion)
    }
    private var displayedExpression: MascotExpression {
        expression == .happy && !reduceMotion && phase.truncatingRemainder(dividingBy: 4.8) > 4.6
            ? .blinking : expression
    }

    var body: some View {
        MascotArtwork(style: style, expression: displayedExpression, hasMoustache: hasMoustache)
            .rotationEffect(.degrees(motion.rotation))
            .scaleEffect(motion.scale, anchor: .bottom)
            .offset(y: motion.lift)
    }
}

/// Bounded motion keeps the cat inside its slot, even while the tour changes layout.
struct MascotMotion {
    let rotation: Double
    let lift: Double
    let scale: Double

    init(expression: MascotExpression, elapsed: TimeInterval, reduceMotion: Bool) {
        guard !reduceMotion else { rotation = 0; lift = 0; scale = 1; return }
        let time = max(0, elapsed)
        switch expression {
        case .thinking:
            rotation = sin(time * 4) * 4
            lift = sin(time * 3) * 1.5
            scale = 1 + sin(time * 5) * 0.015
        case .listening:
            rotation = sin(time * 2.4) * 2.5
            lift = sin(time * 3.5) * 2
            scale = 1 + sin(time * 4) * 0.025
        case .celebrating:
            rotation = sin(time * 5) * 7
            lift = -abs(sin(time * 5)) * 4
            scale = 1 + sin(time * 5) * 0.025
        case .sad:
            rotation = sin(time * 14) * max(0, 1 - time) * 4
            lift = 0
            scale = 1
        case .happy, .blinking:
            rotation = sin(time * 2.5) * 2
            lift = sin(time * 3) * 1.5
            scale = 1
        }
    }
}
