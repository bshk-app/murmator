import AppKit
import SwiftUI

/// A real accessible text view for the At the caret lesson. The tour reads its
/// caret directly (`onMake` hands the view over), so it works without Accessibility.
struct CaretDemoEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var editable: Bool
    var onMake: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 15)
        view.textColor = .labelColor
        view.textContainerInset = CGSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.setSelectedRange(selection)
        view.delegate = context.coordinator
        view.setAccessibilityLabel(String(localized: "Try dictation at the caret"))
        view.setAccessibilityIdentifier("onboarding-caret-field")
        scroll.documentView = view
        onMake(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.isEditable = editable
        if view.string != text {
            view.string = text
            view.setSelectedRange(selection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaretDemoEditor
        var updating = false
        init(_ parent: CaretDemoEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }
}
