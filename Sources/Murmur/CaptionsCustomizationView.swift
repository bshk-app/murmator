import AppKit
import MurmurCaptions
import SwiftUI

struct CaptionsCustomizationView: View {
    let overlay: CaptionsOverlay
    let display: String
    let translating: Bool
    @Bindable var preferences: CaptionsPreferences
    @State private var fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $preferences.appearance.fontFamily) {
                    Text("System").tag("")
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Automatic font size", isOn: $preferences.appearance.automaticFontSize)
                if !preferences.appearance.automaticFontSize {
                    HStack {
                        Slider(value: $preferences.appearance.fontSize, in: 14...72, step: 1) { Text("Size") }
                        Text("\(Int(preferences.appearance.fontSize)) pt").monospacedDigit().frame(width: 46)
                    }
                }
                ColorPicker("Original", selection: color(\.textColor), supportsOpacity: false)
                ColorPicker("Translation", selection: color(\.translationColor), supportsOpacity: false)
            }
            Section("Background") {
                ColorPicker("Color", selection: color(\.backgroundColor), supportsOpacity: false)
                HStack {
                    Slider(value: $preferences.appearance.backgroundOpacity, in: 0...1) { Text("Opacity") }
                    Text("\(Int(preferences.appearance.backgroundOpacity * 100))%").monospacedDigit().frame(width: 46)
                }
            }
            Section("Position & size") {
                Button(overlay.model.editing ? "Done moving & resizing" : "Move & resize captions") {
                    overlay.setEditing(!overlay.model.editing, display: display, translating: translating)
                }
                Text("Drag the outlined area to move it. Pull the lower-right corner to resize. Done locks it and lets clicks pass through.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset position & size") { overlay.resetPlacement(display: display) }
                Button("Reset appearance") { preferences.appearance = CaptionsAppearance() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 370, height: 540)
    }

    private func color(_ key: WritableKeyPath<CaptionsAppearance, CaptionsColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: preferences.appearance[keyPath: key].nsColor) },
                set: { preferences.appearance[keyPath: key] = CaptionsColor(NSColor($0)) })
    }
}

/// Sits over the caption text only while unlocked. Native mouse coordinates
/// avoid cumulative SwiftUI drag deltas when the window itself moves.
final class CaptionsInteractionView: NSView {
    var minimumSize = CGSize(width: 320, height: 100)
    var onChange: ((NSRect) -> Void)?
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private var resizing = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(NSRect(x: bounds.maxX - 28, y: 0, width: 28, height: 28), cursor: .crosshair)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        let point = convert(event.locationInWindow, from: nil)
        resizing = point.x >= bounds.maxX - 28 && point.y <= 28
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        onChange?(Self.dragged(frame: startFrame, dx: point.x - startMouse.x, dy: point.y - startMouse.y,
                               resizing: resizing, minimum: minimumSize))
    }

    static func dragged(frame: NSRect, dx: CGFloat, dy: CGFloat, resizing: Bool, minimum: CGSize) -> NSRect {
        guard resizing else { return frame.offsetBy(dx: dx, dy: dy) }
        let height = max(minimum.height, frame.height - dy)
        return NSRect(x: frame.minX, y: frame.maxY - height,
                      width: max(minimum.width, frame.width + dx), height: height)
    }
}

struct CaptionsInteractionSurface: NSViewRepresentable {
    let minimumSize: CGSize
    let onChange: (NSRect) -> Void
    func makeNSView(context: Context) -> CaptionsInteractionView { CaptionsInteractionView() }
    func updateNSView(_ view: CaptionsInteractionView, context: Context) {
        view.minimumSize = minimumSize
        view.onChange = onChange
    }
}
