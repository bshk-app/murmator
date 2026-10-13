import AppKit
import SwiftUI

/// The captions themselves: the transcript and, when the layout has room for
/// it, the translation under it, on the appearance's background. The host
/// decides where the band goes — a floating panel, a strip under a slide.
public struct CaptionsBand: View {
    let confirmed: String
    let partial: String
    let translation: String
    let layout: CaptionsLayout
    let appearance: CaptionsAppearance

    /// The translation track is shown when `layout.translationLines > 0`.
    public init(confirmed: String, partial: String, translation: String,
                layout: CaptionsLayout, appearance: CaptionsAppearance) {
        self.confirmed = confirmed
        self.partial = partial
        self.translation = translation
        self.layout = layout
        self.appearance = appearance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: layout.trackGap) {
            CaptionsTrack(confirmed: confirmed, partial: partial, size: layout.fontSize,
                          color: appearance.textColor.nsColor, family: appearance.fontFamily)
                .frame(height: CaptionsLayout.trackHeight(lines: layout.transcriptLines, size: layout.fontSize, family: layout.fontFamily))
            if layout.translationLines > 0 {
                CaptionsTrack(confirmed: translation, size: layout.translationFontSize,
                              color: appearance.translationColor.nsColor, family: appearance.fontFamily)
                    .frame(height: CaptionsLayout.trackHeight(lines: layout.translationLines, size: layout.translationFontSize, family: layout.fontFamily))
            }
        }
        .padding(layout.padding)
        .frame(width: layout.bandSize.width, height: layout.bandSize.height, alignment: .topLeading)
        .background(Color(nsColor: appearance.backgroundColor.nsColor).opacity(appearance.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: layout.padding * 0.5, style: .continuous))
    }
}
