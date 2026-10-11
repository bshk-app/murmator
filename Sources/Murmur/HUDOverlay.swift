import AppKit
import MurmurKit
import Observation
import SwiftUI

/// Floating dictation HUD (design: MurMur.dc.html). A non-activating, click-through
/// borderless NSPanel (we type into another app's field at the same time) hosting a
/// SwiftUI glass pill that adapts to light/dark. Three states — listening,
/// transcribing (two-tier coloured text), error.
///
/// Room-scale subtitles are deliberately NOT a variant of this panel: they need
/// geometry derived from the target screen, an opaque backdrop and a session that
/// outlives one utterance. They live in `CaptionsOverlay`.

@Observable
final class HUDModel {
    /// `finalizing` is the gap between the stop gesture and the corrected text:
    /// the microphone is already off, so the level bars must stop with it.
    enum Phase { case listening, transcribing, finalizing, finished, error }
    var phase: Phase = .listening
    var confirmed = ""
    var partial = ""
    var lang = "Auto"
    var errorText = "Open Privacy in Settings →"
    var truncated = false         // older words were dropped — the view leads with an ellipsis
    var submits = false           // this utterance ends with Return
    var recording = false
    var showStop = false          // toggle-mode: HUD shows a clickable Stop
    /// Return finishes this utterance and Escape drops it. Said on the pill
    /// because nothing else would tell you: the key you started with is not
    /// the key you finish with.
    var confirmsWithReturn = false
    var shortcutLabel = ""
    /// Two-line translate mode. Empty means the mode is off or the translation
    /// has not arrived, and the pill stays one line — the row is not reserved,
    /// so plain dictation looks exactly as it did.
    var translation = ""
    /// Whether `translation` came from the CTranslate2 quality engine rather
    /// than the fast fallback. Purely informational - the same text is pasted
    /// either way - so it drives a small label, not a layout change.
    var translationIsQuality = false
    /// The translation is being produced. Shown as its own line so the pill
    /// does not resize twice: once for the placeholder, once for the text.
    var translating = false
    /// Single source of truth for "is the second line on screen right now" -
    /// shared by the view (whether to render `translationLine`) and the panel
    /// (whether to reserve the extra height it needs), so the two can never
    /// drift into a window sized for one answer while the view renders the
    /// other.
    var showsTranslationRow: Bool { !translation.isEmpty || translating }
    /// The language being translated into, as a badge tag ("EN"), or empty
    /// when the mode is off. The design pairs it with `lang` as
    /// `{{ langTag }} → {{ targetTag }}`: the second line is much easier to
    /// read as deliberate once the header says where it is going.
    var target = ""
    var onStop: () -> Void = {}
    /// `HUDStyle.compact`, or `.caret` with no caret to sit by; latched for
    /// the utterance at `begin`.
    var compact = false
    /// `HUDStyle.caret` found the caret at `begin`: the draft is drawn there.
    /// Latched for the utterance, like `compact`.
    var caretAnchored = false
    /// The draft at the caret, laid out.
    var ghost: GhostState?

    /// The take is live or finishing - the only phases the small presentations
    /// cover. An error must be read, and so must a transcript that could not
    /// be delivered (`.finished` only shows when the pill is the one place
    /// the words still are).
    private var isLive: Bool { phase == .listening || phase == .transcribing || phase == .finalizing }
    /// The small fixed capsule rather than the transcript pill.
    var showsCompactPill: Bool { compact && isLive }
    /// The draft drawn at the caret.
    var showsCaretIndicator: Bool { caretAnchored && isLive }
    /// The compact capsule's width, fixed for the utterance at `begin`: room
    /// for the bars and every badge this utterance can come to show, so one
    /// arriving never widens it.
    var compactWidth = HUDController.compactPillSize.width
}

/// The draft at the caret, as `HUDView` draws it: lines in screen
/// coordinates, and the panel they are drawn in.
struct GhostState: Equatable {
    var font: NSFont
    var lineHeight: CGFloat
    var lines: [GhostLine]
    /// The panel's frame. Fixed while the caret stays put, so the window does
    /// not resize with every word.
    var canvas: CGRect
    /// Fixed for the utterance, like the compact capsule's width.
    var markerWidth: CGFloat
}

/// How much text the pill can hold, derived from its own geometry: a 460pt column
/// at 21pt fits ~36 characters per line, and 230pt of usable panel height at 31pt
/// per line fits 5. The character budget targets one line LESS, which is what keeps
/// `maxLines` an emergency guard instead of a routine truncation. Recompute both
/// together if the font, the column width or the panel size changes.
enum HUDCapacity {
    static let maxChars = 145
    static let maxLines = 5
}

// MARK: - Building blocks

/// Animated orange level bars (the `murbar` keyframe: scaleY .32↔1, staggered).
private struct LevelBars: View {
    var color: Color
    var count: Int = 4
    var barHeight: CGFloat = 13
    @State private var up = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: barHeight)
                    .scaleEffect(y: up ? 1 : 0.32, anchor: .center)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .onAppear { up = true }
    }
}

/// Pulsing status dot (`murpulse`).
private struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(on ? 0.4 : 1).scaleEffect(on ? 0.78 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Three dots lighting up in turn: the microphone is off and the text is
/// being finished. Bars would claim it is still listening.
private struct WaitDots: View {
    var color: Color
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle().fill(color).frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: on)
            }
        }
        .onAppear { on = true }
    }
}

// MARK: - HUD view

private struct HUDView: View {
    let model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if model.showsCaretIndicator, let ghost = model.ghost {
            // Its panel is the area the lines can cover, and room for their
            // shadow.
            ghostText(ghost)
        } else {
            Group {
                if model.showsCompactPill {
                    compactPill
                } else {
                    switch model.phase {
                    case .error:        mascotBubble(.error) { errorPill }
                    case .listening:    mascotBubble(.listening) { listeningPill }
                    case .transcribing: mascotBubble(.transcribing) { transcribePill }
                    // Same face as live decoding: the work is the same, only the audio has
                    // stopped arriving. A dedicated mascot state can slot in here.
                    case .finalizing:   mascotBubble(.transcribing) { transcribePill }
                    case .finished:     mascotBubble(.success) { transcribePill }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, HUDController.bottomInset)
            .padding(.horizontal, HUDController.sideInset)
        }
    }

    /// `HUDStyle.caret`: what is being heard, drawn where it will be
    /// inserted, in the field's own type. Each line sits on a glass backing:
    /// the field's colours are unknown, and the draft may be drawn over text
    /// after the caret. No Stop button - the draft sits on what you are
    /// writing, so it takes no clicks; the key that started the take ends it.
    private func ghostText(_ ghost: GhostState) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ghost.lines.enumerated()), id: \.offset) { _, line in
                ghostLine(line, ghost)
                    .offset(x: line.origin.x - GhostText.padding - ghost.canvas.minX,
                            y: ghost.canvas.maxY - line.origin.y - ghost.lineHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // One shadow for the whole block, so lines that touch do not darken
        // each other's edge.
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 4, y: 1)
    }

    private func ghostLine(_ line: GhostLine, _ ghost: GhostState) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(6, ghost.lineHeight / 3), style: .continuous)
        let hasText = line.elided || !line.words.isEmpty
        return HStack(spacing: 0) {
            if hasText {
                if let clip = line.clip {
                    ghostWords(line).font(Font(ghost.font)).lineLimit(1).truncationMode(.head)
                        .frame(width: clip, alignment: .trailing)
                } else {
                    ghostWords(line).font(Font(ghost.font)).lineLimit(1).fixedSize()
                }
            }
            if line.hasMarker {
                if hasText { Color.clear.frame(width: GhostText.markerGap) }
                ghostMarker(ghost)
            }
        }
        .frame(height: ghost.lineHeight)
        .padding(.horizontal, GhostText.padding)
        .background(Mur.glass(scheme), in: shape)
        .background(.ultraThinMaterial, in: shape)
    }

    /// Settled words in the transcript's ink, words that may still change in
    /// its draft grey - the full pill's two tiers.
    private func ghostWords(_ line: GhostLine) -> Text {
        let draft = Mur.draft(scheme), crisp = Mur.crisp(scheme)
        var text = line.elided ? Text(verbatim: GhostText.ellipsis).foregroundColor(draft) : Text(verbatim: "")
        for (i, word) in line.words.enumerated() {
            text = text + Text(verbatim: (i > 0 || line.elided ? " " : "") + word.text)
                .foregroundColor(word.confirmed ? crisp : draft)
        }
        return text
    }

    /// Stands in for the app's caret, which the backing covers: bars while
    /// listening, dots once the microphone is off, and how the take ends.
    private func ghostMarker(_ ghost: GhostState) -> some View {
        HStack(spacing: HUDController.markerGlyphGap) {
            Group {
                if model.phase == .finalizing {
                    WaitDots(color: Mur.accent)
                        .accessibilityLabel(Text("Finalizing…"))
                } else {
                    LevelBars(color: Mur.accent, count: 4, barHeight: min(11, ghost.lineHeight * 0.55))
                        .accessibilityLabel(Text("Listening…"))
                }
            }
            .frame(width: HUDController.markerBarsWidth)
            Group {
                if model.submits {
                    Text("⏎").foregroundStyle(Mur.accent)
                        .accessibilityLabel(Text("Will press Return when finished"))
                } else if model.confirmsWithReturn, model.recording {
                    Text("⏎")
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
                        .accessibilityLabel(Text("Press Return to insert, Escape to cancel"))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .fixedSize()
        }
        .frame(width: ghost.markerWidth, alignment: .leading)
    }

    /// `HUDStyle.compact`: one capsule that keeps its size for the whole
    /// utterance - the badges have reserved room on the right, so nothing
    /// inside shifts either when one appears.
    private var compactPill: some View {
        HStack(spacing: 8) {
            Group {
                if model.phase == .finalizing {
                    WaitDots(color: Mur.accent)
                        .accessibilityLabel(Text("Finalizing…"))
                } else {
                    LevelBars(color: Mur.accent, count: 5, barHeight: 14)
                        .accessibilityLabel(Text("Listening…"))
                }
            }
            .frame(width: 30)
            Spacer(minLength: 0)
            Group {
                if model.submits {
                    submitBadge
                } else if model.confirmsWithReturn, model.recording {
                    // Just the glyph: "⏎ Insert" spelled out would not fit, and
                    // the quiet colour already tells it apart from the accent ⏎
                    // that sends.
                    Text("⏎").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(scheme == .dark ? Color.white.opacity(0.09) : Mur.ink.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .accessibilityLabel(Text("Press Return to insert, Escape to cancel"))
                }
            }
            // A glyph squeezed by its neighbours truncates to an ellipsis.
            .fixedSize()
            if model.showStop { stopButton }
        }
        .padding(.horizontal, 14)
        .frame(width: model.compactWidth, height: HUDController.compactPillSize.height)
        // The full pill's 22pt shadow is sized for a 460pt slab; under a
        // capsule this small it reads as a smudge.
        .murPill(scheme, radius: 16, border: borderColor,
                 shadowRadius: 10, shadowY: 4)
    }

    // Header: animated bars + language badge; the mascot overlaps the pill edge.
    private var header: some View {
        HStack(spacing: 10) {
            // Bars mean "we are hearing you". Once the microphone is off they would
            // be a lie, so the same slot carries the wait instead.
            if model.phase == .finalizing {
                Text("Finalizing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Mur.accent)
            } else {
                LevelBars(color: Mur.accent, count: 4, barHeight: 13)
            }
            Spacer(minLength: 8)
            if model.submits { submitBadge }
            if model.confirmsWithReturn, model.recording { returnBadge }
            langBadge
            if model.showStop { stopButton }
        }
    }

    /// `RU` alone, or `RU → EN` while translating, with the target in accent.
    ///
    /// The arrow is what makes the second line legible as a translation rather
    /// than as a stray grey paragraph, so it is the badge - not the type - that
    /// carries the explanation. Accent is safe on the target tag: it sits in
    /// the header, far from the transcript's newest-word flash, so the two
    /// never merge into one block the way an accent-coloured second line did.
    private var langBadge: some View {
        let translating = !model.target.isEmpty
        return HStack(spacing: 5) {
            Text(model.lang.uppercased())
            if translating {
                Text("\u{2192}").opacity(0.5)
                Text(model.target.uppercased()).foregroundStyle(Mur.accent)
            }
        }
        .font(.system(size: 10, weight: .medium)).tracking(0.4)
        .foregroundStyle(scheme == .dark
                         ? Color.white.opacity(translating ? 0.45 : 0.4)
                         : Mur.ink.opacity(0.5))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(scheme == .dark ? Color.white.opacity(0.08) : Mur.ink.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    /// Clickable Stop (toggle mode). The panel accepts mouse events while this shows.
    private var stopButton: some View {
        Button(action: model.onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Mur.ink.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(scheme == .dark ? Color.white.opacity(0.12) : Mur.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // Two-tier coloured transcript + blinking accent caret.
    private var transcribePill: some View {
        let translating = model.showsTranslationRow
        return VStack(alignment: .leading, spacing: 9) {
            header
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                // The caret means "more is still coming here". In translate mode
                // the live edge is the second line, so a caret on the first one
                // points at the wrong place - the design drops it there, and
                // shrinks this line 21 -> 20 to give the translation its room.
                (translating
                 ? transcript
                 : transcript + Text("▏").foregroundStyle(Mur.accent.opacity(on ? 1 : 0)))
                    .font(.system(size: translating ? 20 : 21))
                    .lineSpacing(6)
                    // Hard layout guard behind the character clamp: whatever slips past
                    // the estimate, the text still cannot outgrow the panel.
                    .lineLimit(HUDCapacity.maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if translating {
                translationLine
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: 460, alignment: .leading)
        .murPill(scheme, radius: 16, border: borderColor)
    }

    /// The translation, under a hairline separator.
    ///
    /// Per MurMur.dc.html's "Live translation" block: `400 17px/1.5` in
    /// `rgba(255,255,255,.66)`, under a `rgba(255,255,255,.1)` rule with 11pt
    /// of air either side. The hierarchy against the 20pt/500 transcript is
    /// deliberate - this line is what the machine made of what you said, and
    /// the header's `RU → EN` badge, not the type, is what explains it.
    /// No accent here either: accent marks the newest confirmed word directly
    /// above, and painting the translation with it merged the two into a
    /// single orange block.
    private var translationLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Mur.hairline(scheme))
                .frame(height: 1)
                // 9 from the enclosing VStack + 2 = the design's 11 above the
                // rule; 11 below it.
                .padding(.top, 2)
                .padding(.bottom, 11)
            if model.translating {
                Text("Translating\u{2026}")
                    .font(.system(size: 15))
                    .foregroundStyle(Mur.draft(scheme))
            } else {
                Text(model.translation)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .foregroundStyle(Mur.secondary(scheme))
                    .lineLimit(HUDCapacity.maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Quiet by design: it says which engine won, not that the fast
                // one is somehow inferior - most directions have no quality
                // model at all, and that is the ordinary case, not a warning.
                if model.translationIsQuality {
                    Text("Quality translation")
                        .font(.system(size: 11))
                        .foregroundStyle(Mur.draft(scheme))
                        .padding(.top, 7)
                }
            }
        }
    }

    private var transcript: Text {
        let crisp = Mur.crisp(scheme), draft = Mur.draft(scheme)
        let conf = Self.words(model.confirmed)
        let part = Self.words(model.partial)
        // The marker is styling, not content: kept out of `model.confirmed` so it
        // can't be counted as a word and steal the newest-word accent below.
        var t = model.truncated ? Text("… ").foregroundColor(draft) : Text("")
        for (i, w) in conf.enumerated() {
            // Approximated "refine flash": the newest confirmed word glows accent.
            let hot = i == conf.count - 1
            t = t + Text(w).foregroundColor(hot ? Mur.accent : crisp).fontWeight(.medium) + Text(" ")
        }
        for w in part {
            t = t + Text(w).foregroundColor(draft).fontWeight(.regular) + Text(" ")
        }
        if conf.isEmpty, part.isEmpty {
            return Text("Listening…").foregroundColor(draft)
        }
        return t
    }

    private var listeningPill: some View {
        HStack(spacing: 13) {
            PulseDot(color: Mur.accent, size: 8)
            Text("Listening…").font(.system(size: 15))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : Mur.ink)
            LevelBars(color: Mur.accent, count: 5, barHeight: 16)
            if model.submits { submitBadge }
            if model.confirmsWithReturn { returnBadge }
            if model.showStop { stopButton } else { hotkeyBadge }
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .murPill(scheme, radius: 14, border: borderColor)
    }

    private var errorPill: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No microphone access").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.95) : Mur.ink)
                Text(model.errorText).font(.system(size: 11.5))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.55) : Mur.ink.opacity(0.6))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .murPill(scheme, radius: 14, border: Mur.error.opacity(0.4))
    }

    private func mascotBubble<Content: View>(
        _ mood: MascotMood,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .topLeading) {
            content()
            mascotBadge(mood).offset(x: -38, y: -38)
        }
        .padding(.leading, 38)
        .padding(.top, 38)
    }

    private func mascotBadge(_ mood: MascotMood) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return MurmatorMascot(mood: mood, size: 42)
            .padding(4)
            .background(Mur.glass(scheme), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(mood == .error ? Mur.error.opacity(0.4) : borderColor,
                                        lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.16), radius: 10, y: 6)
            .overlay(alignment: .bottomTrailing) {
                if mood == .error {
                    Circle().fill(Mur.error).frame(width: 12, height: 12)
                        .overlay(Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                        .offset(x: 3, y: 2)
                }
            }
    }

    /// Marks an utterance that will press Return when it lands. Two shortcuts only
    /// work if you can see which one you're holding, and this is the one moment the
    /// mistake is still catchable — before the message is sent.
    private var submitBadge: some View {
        Text("⏎").font(.system(size: 11, weight: .medium))
            .foregroundStyle(Mur.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Mur.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text("Will press Return when finished"))
    }

    private var hotkeyBadge: some View {
        Text("Release \(model.shortcutLabel)").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : Mur.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text("Release \(model.shortcutLabel) to finish"))
    }

    /// How a tap-on dictation ends. The submit badge above is the accent ⏎
    /// ("this will send"); this one is quiet and spelled out, so the two do
    /// not read as the same promise.
    private var returnBadge: some View {
        Text("⏎ Insert").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : Mur.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text("Press Return to insert, Escape to cancel"))
    }

    private var borderColor: Color {
        scheme == .dark ? Color.white.opacity(0.1) : Mur.ink.opacity(0.1)
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

/// Glass-pill background: blurred material + warm tint + hairline border + shadow.
private extension View {
    func murPill(_ scheme: ColorScheme, radius: CGFloat, border: Color,
                 shadowRadius: CGFloat = 22, shadowY: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Mur.glass(scheme), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.18), radius: shadowRadius, y: shadowY)
    }
}

// MARK: - Panel controller

@MainActor
final class HUDController {
    // Not private: MurmurTests reads it via @testable import to catch state
    // (like the quality-translation label) leaking across sessions - a real
    // regression here reads as an obviously wrong label on screen, which is
    // exactly the kind of bug a test should catch before a person does.
    let model = HUDModel()
    private var panel: NSPanel?
    // Not private: a test confirms the panel actually grows to fit a
    // translation row rather than clipping it - the exact defect a live
    // screenshot caught, where the fixed-height panel clipped the
    // translation's last line at the window edge.
    var panelSize: CGSize? { panel?.frame.size }
    var panelFrame: CGRect? { panel?.frame }
    var panelTakesClicks: Bool { panel.map { !$0.ignoresMouseEvents } ?? false }
    var panelIsVisible: Bool { panel?.isVisible ?? false }
    private var hideWork: DispatchWorkItem?
    /// Counts showings. A fade ends by ordering the panel out, and a take
    /// started before it finished - tap right ⌘ straight after Return -
    /// must not be hidden by it.
    private var showing = 0
    /// Finds the caret for `HUDStyle.caret`, and when asked the field's type.
    /// Swapped in tests, which have no app to ask.
    var locateCaret: @MainActor (_ readingFont: Bool) -> CaretLocator.Lookup = {
        CaretLocator.locate(readingFont: $0)
    }
    /// How often the draft checks that the caret is where it was: the window
    /// can scroll under it while you speak.
    var caretTrackingInterval: Duration = .milliseconds(250)
    /// Where the draft is drawn; nil while the panel sits at the bottom of
    /// the screen.
    private var spot: CaretSpot?
    /// The draft's type, settled at `begin`.
    private var ghostFont: NSFont?
    private var ghostMarkerWidth: CGFloat = 0
    private var caretTracking: Task<Void, Never>?
    private static let baseSize = NSSize(width: 940, height: 260)
    /// Where the pill sits inside the panel. Shared with `HUDView`, which
    /// pads by exactly these, so a panel sized from them fits its pill.
    nonisolated static let bottomInset: CGFloat = 30
    nonisolated static let sideInset: CGFloat = 40
    /// The widest compact pill (`compactWidth(returnGlyph: true, stop: true)`),
    /// which the compact panel is sized for.
    nonisolated static let compactPillSize = CGSize(width: 130, height: 36)
    /// 14pt either side, the 30pt bars, 8pt of air before the right edge, and
    /// for each badge 8pt plus the badge: ⏎ 26, Stop 22. A hold-to-talk take
    /// shows bars alone, so its capsule is just that wide.
    nonisolated static func compactWidth(returnGlyph: Bool, stop: Bool) -> CGFloat {
        14 + 30 + (returnGlyph ? 8 + 26 : 0) + (stop ? 8 + 22 : 0) + 8 + 14
    }
    /// Just the capsule, its insets and room for its shadow - not the full
    /// panel. In toggle mode the panel takes clicks, and an invisible
    /// 940×260 window around a pill this small would swallow them for no
    /// reason.
    private static let compactPanelSize = NSSize(width: compactPillSize.width + 2 * sideInset,
                                                 height: compactPillSize.height + bottomInset + 30)
    /// The draft's marker: the 24pt bars and, when it can show, 4pt and the
    /// 12pt ⏎ glyph.
    nonisolated static let markerBarsWidth: CGFloat = 24
    nonisolated static let markerGlyphGap: CGFloat = 4
    nonisolated static func markerWidth(returnGlyph: Bool) -> CGFloat {
        markerBarsWidth + (returnGlyph ? markerGlyphGap + 12 : 0)
    }
    /// Room around the draft for its shadow.
    nonisolated static let ghostMargin: CGFloat = 8
    /// Extra room the translation row needs at its worst case: the hairline,
    /// the 11pt of air either side of it, up to `HUDCapacity.maxLines` lines
    /// at the translation's own 17pt/1.5 (25.5pt each, per the design), and
    /// the "Quality translation" label with its 7pt gap: 2 + 1 + 11 + 127.5 +
    /// 20 = 161.5, rounded up. `baseSize` was sized for the transcript alone -
    /// see `HUDCapacity`'s doc comment for that derivation - so a translation
    /// showing needs this added on top of it, not instead of it. Kept tight
    /// rather than generously over-reserved because in toggle mode the panel
    /// takes mouse events (`ignoresMouseEvents = !interactive`), so spare
    /// height is not free: it would swallow clicks above the pill.
    private static let translationExtraHeight: CGFloat = 165
    /// `baseSize` plus room for the translation row exactly when one is on
    /// screen (`HUDModel.showsTranslationRow`), so plain dictation keeps the
    /// panel it always had and nothing is clipped when a second line joins
    /// it. Read fresh rather than cached: it must reflect `model` at the
    /// moment a resize actually happens, not whatever it was when the panel
    /// was first created.
    private var currentSize: NSSize {
        if model.showsCaretIndicator, let ghost = model.ghost { return ghost.canvas.size }
        if model.showsCompactPill { return Self.compactPanelSize }
        return NSSize(width: Self.baseSize.width,
                      height: Self.baseSize.height + (model.showsTranslationRow ? Self.translationExtraHeight : 0))
    }

    /// Reveal the HUD for a new utterance. `interactive` (toggle mode) makes the
    /// panel accept clicks so the Stop button works. `style` is read once
    /// here: switching it mid-utterance would resize the pill under the user.
    func begin(lang: String, target: String = "", interactive: Bool = false, submits: Bool = false,
               confirmsWithReturn: Bool = false, style: HUDStyle = .current,
               shortcutLabel: String = "", onStop: @escaping () -> Void = {}) {
        hideWork?.cancel(); hideWork = nil
        stopTrackingCaret()
        let panel = ensurePanel()
        // Looked for before anything is shown, and once: where to put the
        // HUD is decided for the utterance, like its style.
        var spot: CaretSpot?
        if style == .caret, case .found(let found) = locateCaret(true) { spot = found }
        self.spot = spot
        ghostFont = spot.map { GhostText.font(for: $0.font, caretHeight: $0.caret.height) }
        model.lang = lang
        model.target = target
        model.submits = submits
        model.confirmsWithReturn = confirmsWithReturn
        model.shortcutLabel = shortcutLabel
        model.caretAnchored = spot != nil
        // No caret to sit by: the compact capsule, which is what `.caret`
        // falls back to rather than the full pill.
        model.compact = style == .compact || (style == .caret && spot == nil)
        // A tap-on take can turn into one that sends (Return pressed twice)
        // after it starts, so its ⏎ slot is there from the start.
        model.compactWidth = Self.compactWidth(returnGlyph: submits || confirmsWithReturn, stop: interactive)
        ghostMarkerWidth = Self.markerWidth(returnGlyph: submits || confirmsWithReturn)
        model.ghost = nil
        model.phase = .listening
        show(confirmed: "", partial: "")      // also clears a carried-over ellipsis, and lays out the draft
        // A translation left from the previous utterance under a fresh one
        // would read as a translation of it, and so would its quality label.
        model.translation = ""
        model.translationIsQuality = false
        model.translating = false
        model.recording = true
        model.showStop = interactive && spot == nil
        model.onStop = onStop
        panel.ignoresMouseEvents = !model.showStop
        if spot != nil {
            trackCaret()
        } else {
            position(panel)
        }
        reveal(panel)
    }

    /// Live two-tier update.
    func update(confirmed: String, partial: String) {
        show(confirmed: confirmed, partial: partial)
        if model.phase != .error, model.recording {
            model.phase = (model.confirmed.isEmpty && model.partial.isEmpty) ? .listening : .transcribing
        }
    }

    /// The single door into the model's text — both entry points clamp through here,
    /// so what reaches the view is already known to fit the panel.
    private func show(confirmed: String, partial: String) {
        let fitted = HUDTranscript.clamped(confirmed: confirmed, partial: partial,
                                           maxChars: HUDCapacity.maxChars)
        model.confirmed = fitted.confirmed
        model.partial = fitted.partial
        model.truncated = fitted.truncated
        layoutGhost()
    }

    /// Lays the draft out at the caret, and puts the panel where it can be
    /// drawn. The panel only moves when the caret does: its frame is the
    /// area the lines can cover, whatever they hold.
    private func layoutGhost() {
        guard model.showsCaretIndicator, let spot, let font = ghostFont,
              let visible = (Self.screen(containing: spot.caret) ?? NSScreen.main)?.visibleFrame else { return }
        let lineHeight = GhostText.lineHeight(caret: spot.caret.height, font: font)
        let geometry = GhostText.geometry(caret: spot.caret, field: spot.field, singleLine: spot.singleLine,
                                          lineHeight: lineHeight, visible: visible)
        let lines = GhostText.lines(GhostWord.words(confirmed: model.confirmed, partial: model.partial),
                                    elided: model.truncated, in: geometry, marker: ghostMarkerWidth,
                                    measure: { GhostText.measure($0, font: font) })
        let canvas = geometry.region.insetBy(dx: -Self.ghostMargin, dy: -Self.ghostMargin)
        model.ghost = GhostState(font: font, lineHeight: lineHeight, lines: lines, canvas: canvas,
                                 markerWidth: ghostMarkerWidth)
        if let panel, panel.frame != canvas { panel.setFrame(canvas, display: true) }
    }

    /// Surface a mic/permission error in the HUD.
    func error(_ text: String) {
        let panel = ensurePanel()
        model.phase = .error
        if !text.isEmpty { model.errorText = text }
        model.recording = false
        let near = spot?.caret
        leaveCaret()
        position(panel, near: near)
        reveal(panel)
        scheduleHide(after: 3.2)
    }

    /// The stop gesture landed; the corrected text is still being decoded. The mic
    /// is off, so stop pretending to listen and say what is happening instead.
    func finalizing() {
        guard panel != nil else { return }
        hideWork?.cancel(); hideWork = nil
        model.recording = false
        model.showStop = false
        model.phase = .finalizing
    }

    /// Return was pressed again before the text landed: it will be pressed for
    /// the user once the paste is in, and the pill shows the same ⏎ badge a
    /// dictate-and-send utterance does.
    func willSubmit() {
        guard panel != nil else { return }
        model.submits = true
    }

    /// The transcript is ready and the translation is not. Shown as its own
    /// state because translating a long utterance takes long enough to notice,
    /// and a pill that simply sat there would read as finished-but-wrong.
    func translating() {
        guard panel != nil else { return }
        model.translating = true
        fitPanel()
    }

    /// End the presentation according to what happened to the transcript. An
    /// explicit stop dismisses at once; only undelivered text earns a wait.
    func finish(_ finalText: String, delivery: TranscriptDelivery, translation: String = "",
               translationIsQuality: Bool = false) {
        guard panel != nil else { return }
        model.recording = false
        model.showStop = false
        let policy = StopPresentation.policy(for: delivery, textIsEmpty: finalText.isEmpty)
        model.translating = false
        model.translation = translation
        model.translationIsQuality = translationIsQuality
        fitPanel()
        if policy.showsText, !finalText.isEmpty {
            show(confirmed: finalText, partial: "")
            model.phase = .finished
            if let message = policy.message { model.errorText = message }
            fitPanel()          // a compact pill has no room for the words
        }
        guard policy.linger > 0 else { return dismiss() }
        scheduleHide(after: policy.linger)
    }

    /// Fade now, cancelling any pending hide.
    func dismiss() {
        hideWork?.cancel(); hideWork = nil
        fadeOut()
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        // The draft gives way to the pasted text under it: quickly, or the
        // two would be read on top of each other.
        let duration = model.showsCaretIndicator ? 0.12 : 0.25
        stopTrackingCaret()
        guard let panel else { return }
        let fading = showing
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            // Shown again while it faded: that showing owns the panel now.
            guard self?.showing == fading else { return }
            panel.orderOut(nil)
        })
    }

    private func reveal(_ panel: NSPanel) {
        showing += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    /// Keeps the draft on the caret while the take is live: the window can
    /// scroll under it, or the field move. While the caret cannot be found
    /// the draft stays where the text last was, rather than jumping to the
    /// bottom of the screen mid-sentence.
    private func trackCaret() {
        caretTracking = Task { [weak self] in
            while true {
                guard let interval = self?.caretTrackingInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.model.showsCaretIndicator,
                      let spot = self.spot else { return }
                switch self.locateCaret(false) {
                case .found(let found):
                    guard found.caret != spot.caret || found.field != spot.field else { continue }
                    // The type stays the one read at the start.
                    self.spot = CaretSpot(found.caret, field: found.field, font: spot.font,
                                          singleLine: found.singleLine)
                    self.layoutGhost()
                case .notFound:
                    continue
                case .stalled:
                    // Asking again would freeze Murmur for the timeout
                    // each time; the draft stays where it is.
                    return
                }
            }
        }
    }

    private func stopTrackingCaret() {
        caretTracking?.cancel()
        caretTracking = nil
    }

    /// The panel is no longer at the caret.
    private func leaveCaret() {
        stopTrackingCaret()
        spot = nil
        model.ghost = nil
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        return screenIndex(containing: rect, in: screens.map(\.frame)).map { screens[$0] }
    }

    /// The display a caret is on: the one holding its midpoint - a caret on
    /// the seam between two displays is on the right-hand one, where its
    /// text starts - or, for a caret on no display's area, the nearest edge.
    nonisolated static func screenIndex(containing rect: CGRect, in frames: [CGRect]) -> Int? {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        return frames.firstIndex { $0.contains(mid) }
            ?? frames.firstIndex { $0.intersects(rect.insetBy(dx: -1, dy: -1)) }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: currentSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: currentSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Resize in place, growing upward from the same bottom centre: AppKit's
    /// frame is bottom-anchored and the pill sits at the bottom of the panel
    /// (`alignment: .bottom`), so keeping `minY` and `midX` keeps the pill
    /// exactly where it was. Two causes mid-utterance: the translation row
    /// arriving or clearing, and a compact pill handing over to the full one
    /// to show text that could not be delivered. `position(_:)` does the
    /// fuller job (screen + both axes) for a new utterance; re-running the
    /// screen lookup here - the cursor may since have moved to a different
    /// display - would be a surprising reason for the panel to jump.
    private func fitPanel() {
        guard let panel else { return }
        // Its size is fixed for the utterance, and its place is the caret's.
        if model.showsCaretIndicator { return }
        if let caret = spot?.caret {
            // Handing over from the caret to the full pill, for an error or
            // words that could not be typed: those belong at the bottom of
            // the screen the text is on, not on top of the text.
            leaveCaret()
            position(panel, near: caret)
            return
        }
        let size = currentSize
        let old = panel.frame
        guard old.size != size else { return }
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.minY,
                              width: size.width, height: size.height), display: true)
    }

    /// Bottom centre of the screen the caret was on, if the panel is leaving
    /// it, or else of the screen under the mouse.
    private func position(_ panel: NSPanel, near caret: CGRect? = nil) {
        guard let screen = caret.flatMap(Self.screen(containing:)) ?? NSScreen.underCursor else { return }
        let v = screen.visibleFrame
        let size = currentSize
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 24,
                              width: size.width, height: size.height), display: true)
    }
}
