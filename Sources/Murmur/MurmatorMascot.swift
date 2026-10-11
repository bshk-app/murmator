import Foundation
import SwiftUI

enum MascotMood: Equatable {
    case idle, listening, transcribing, success, error

    var animation: (row: Int, count: Int, interval: TimeInterval, repeats: Bool) {
        switch self {
        case .idle: return (0, 6, 0.18, true)
        case .listening: return (6, 6, 0.17, true)
        case .transcribing: return (7, 6, 0.14, true)
        case .success: return (4, 5, 0.17, false)
        // Hold the disappointed pose instead of returning to neutral.
        case .error: return (5, 5, 0.16, false)
        }
    }

    func frame(at elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        if reduceMotion { return self == .error ? 4 : 0 }
        let position = max(0, elapsed) / animation.interval
        if animation.repeats {
            return Int(position.truncatingRemainder(dividingBy: Double(animation.count)))
        }
        return Int(min(position, Double(animation.count - 1)))
    }
}

/// Plays the selected companion in the HUD, menu, and onboarding.
struct MurmatorMascot: View {
    let mood: MascotMood
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MascotStyle.defaultsKey) private var storedStyle = MascotStyle.defaultStyle.rawValue
    @AppStorage(MascotStyle.moustacheDefaultsKey) private var hasMoustache = true

    var body: some View {
        Playback(mood: mood, style: .resolve(storedStyle), size: size, reduceMotion: reduceMotion, hasMoustache: hasMoustache)
            .id(mood)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct Playback: View {
        let mood: MascotMood
        let style: MascotStyle
        let size: CGFloat
        let reduceMotion: Bool
        let hasMoustache: Bool
        @State private var start = Date.now
        @State private var finished = false

        var body: some View {
            let animation = mood.animation
            TimelineView(.animation(minimumInterval: animation.interval, paused: reduceMotion || finished)) { context in
                let elapsed = finished ? Double(animation.count) * animation.interval : context.date.timeIntervalSince(start)
                if style == .classic && hasMoustache {
                    let column = mood.frame(at: elapsed, reduceMotion: reduceMotion)
                    let width = size * 192 / 208
                    Image("murmur_pet")
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width * 8, height: size * 11)
                        .offset(x: -CGFloat(column) * width, y: -CGFloat(animation.row) * size)
                        .frame(width: width, height: size, alignment: .topLeading)
                        .clipped()
                } else {
                    AnimatedMascotPortrait(style: style, expression: mood.expression, elapsed: elapsed, reduceMotion: reduceMotion, hasMoustache: hasMoustache)
                        .frame(width: size, height: size)
                }
            }
            .task(id: reduceMotion) {
                start = .now
                finished = false
                guard !reduceMotion, !animation.repeats else { return }
                do {
                    try await Task.sleep(for: .seconds(Double(animation.count) * animation.interval))
                    finished = true
                } catch {
                    // SwiftUI cancels playback when the state changes or the view disappears.
                }
            }
        }
    }
}

private extension MascotMood {
    var expression: MascotExpression {
        switch self {
        case .idle: .happy
        case .listening: .listening
        case .transcribing: .thinking
        case .success: .celebrating
        case .error: .sad
        }
    }
}
