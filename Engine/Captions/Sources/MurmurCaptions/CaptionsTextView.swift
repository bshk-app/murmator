import AppKit
import QuartzCore
import SwiftUI

/// Stable native text layout with a smoothly scrolling viewport. Keeping the
/// prefix is intentional: cutting an arbitrary word off the head rewraps every
/// visible line. TextKit receives only diff hunks, preserving matching text when
/// the accurate lane corrects the fast draft in several places at once.
@MainActor
public final class CaptionsTextView: NSView {
    let clipView = NSClipView()
    let textView = NSTextView()
    private var fontSize: CGFloat = 0
    private var fontFamily = ""
    private var ink = NSColor.white
    private var confirmedLength = 0
    private var scrollTarget: CGFloat = 0
    private var scrollGeneration = 0
    private var hasText = false
    public var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override public var isFlipped: Bool { true }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        addSubview(clipView)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        clipView.documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `confirmed` is drawn in `color`, the still-changing `partial` draft dimmed after it.
    public func update(confirmed: String, partial: String, size: CGFloat, color: NSColor, family: String = "") {
        guard let storage = textView.textStorage else { return }
        let separator = confirmed.isEmpty || partial.isEmpty ? "" : " "
        let empty = confirmed.isEmpty && partial.isEmpty
        let text = empty ? "…" : confirmed + separator + partial
        let newConfirmedLength = (confirmed as NSString).length
        let styleChanged = fontSize != size || ink != color || fontFamily != family
        let wasEmpty = !hasText
        hasText = !empty
        let edits = CaptionsTextDiff.edits(from: storage.string, to: text)
        guard !edits.isEmpty || confirmedLength != newConfirmedLength || styleChanged else { return }
        storage.beginEditing()
        for edit in edits.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        fontSize = size
        fontFamily = family
        ink = color
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CaptionsLayout.lineSpacing(size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CaptionsAppearance.font(size: size, family: family),
            .paragraphStyle: paragraph,
            .foregroundColor: color,
        ]
        if styleChanged {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        } else {
            var delta = 0
            for edit in edits {
                let length = edit.replacement.utf16.count
                storage.setAttributes(attributes, range: NSRange(location: edit.range.location + delta, length: length))
                delta += length - edit.range.length
            }
        }
        // Promotion may move the boundary even without any text edits. Change
        // color only; do not replace the matching draft or erase its attributes.
        if newConfirmedLength > 0 {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: newConfirmedLength))
        }
        if newConfirmedLength < storage.length {
            storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.72),
                                 range: NSRange(location: newConfirmedLength, length: storage.length - newConfirmedLength))
        }
        confirmedLength = newConfirmedLength
        storage.endEditing()
        positionText(animated: !wasEmpty && !empty && !styleChanged)
    }

    override public func layout() {
        super.layout()
        guard clipView.frame != bounds else { return }
        clipView.frame = bounds
        positionText(animated: false)
    }

    private func positionText(animated: Bool) {
        guard bounds.width > 0,
              let container = textView.textContainer,
              let manager = textView.layoutManager else { return }
        let containerSize = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        if container.containerSize != containerSize { container.containerSize = containerSize }
        manager.ensureLayout(for: container)
        let height = max(bounds.height, ceil(manager.usedRect(for: container).height))
        // A corrected draft can get shorter. Shrinking the document immediately
        // makes NSClipView clamp its bounds, bypassing the scroll animation.
        textView.setFrameSize(CGSize(width: bounds.width, height: max(height, clipView.bounds.maxY)))
        let target = max(0, height - bounds.height)
        guard target != scrollTarget || !animated else { return }
        scrollTarget = target
        scrollGeneration &+= 1
        let generation = scrollGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated && !reduceMotion ? 0.28 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(CGPoint(x: 0, y: target))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrollGeneration == generation else { return }
                self.textView.setFrameSize(CGSize(width: self.bounds.width, height: height))
            }
        })
    }
}

/// One language's lines: `CaptionsTextView` for SwiftUI.
public struct CaptionsTrack: NSViewRepresentable {
    let confirmed: String
    let partial: String
    let size: CGFloat
    let color: NSColor
    let family: String

    public init(confirmed: String, partial: String = "", size: CGFloat, color: NSColor = .white, family: String = "") {
        self.confirmed = confirmed
        self.partial = partial
        self.size = size
        self.color = color
        self.family = family
    }

    public func makeNSView(context: Context) -> CaptionsTextView { CaptionsTextView() }

    public func updateNSView(_ view: CaptionsTextView, context: Context) {
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.update(confirmed: confirmed, partial: partial, size: size, color: color, family: family)
    }
}
