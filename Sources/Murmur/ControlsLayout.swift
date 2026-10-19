import SwiftUI

// The card layout shared by the Murmator window and Settings (design: Claude
// Design «Murmator Mac Controls v4» and «Murmator Mac Settings v1»).

/// An uppercase caption over a warm card of rows.
struct ControlsCard<Content: View>: View {
    let title: LocalizedStringKey
    var footer: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(palette.label)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
            if let footer {
                ControlsNote(text: footer).padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a card: a label column, then the control and its notes.
/// Without a title the control takes the full width.
struct ControlsRow<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var labelWidth: CGFloat = 112
    var last = false
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let title {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink)
                    .frame(width: labelWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(palette.hairline).frame(height: 1) } }
    }
}

struct ControlsNote: View {
    let text: String
    var error = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        Text(verbatim: text).font(.system(size: 12))
            .foregroundStyle(error ? palette.errorText : palette.note)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small switch in the accent with its label beside it.
struct ControlsSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).tint(Mur.accent).labelsHidden()
            Text(title).font(.system(size: 13)).foregroundStyle(MacPalette(scheme).ink)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A text link in the accent text colour.
struct ControlsLink: View {
    let title: LocalizedStringKey
    let perform: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: perform) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MacPalette(scheme).accentText)
        }
        .buttonStyle(.plain)
    }
}
