import MurmurKit
import SwiftUI

/// Step 3 — Speech models. Shows the shared session's real preparation progress
/// (one figure: the session does not report per-model progress) and what each
/// model is for.
struct ModelsScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme
    @State private var showDetails = false

    private var t: OnTheme { OnTheme(scheme) }

    private var stage: String {
        if model.modelsReady { return String(localized: "Speech models ready") }
        guard let progress = model.preparationProgress else { return String(localized: "Preparing speech models…") }
        switch progress.stage {
        case .unloading: return String(localized: "Freeing model memory…")
        case .speech: return String(localized: "Preparing speech models…")
        case .textModel: return String(localized: "Loading text corrector…")
        case .translation: return String(localized: "Preparing translation…")
        case .warmup: return String(localized: "Warming up recognition…")
        }
    }

    var body: some View {
        StepPage(step: .models,
                 title: "Prepare speech recognition",
                 lede: "Models download once and run on this Mac. Loading puts them in memory so a recording can start right away.") {
            Text("Audio and text never leave this Mac.").murFont(12.5).foregroundStyle(t.muted(0.62))
        } controls: {
            Text("Model loading is set in Settings › Model loading.").murFont(12.5).foregroundStyle(t.muted(0.72))
        } stage: {
            VStack(spacing: 0) {
                progressRow
                modelRow("Live model", "Writes words while you speak. Used by Fast and for the Hybrid draft.")
                modelRow("Accurate model", "Refines phrases in Hybrid; recognizes the recording in Accurate.")
                modelRow("Corrector", "Optional. Downloads the first time you switch it on.", last: true)
            }
            .padding(.horizontal, 16)
            .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
        } status: {
            if let error = model.downloadError {
                StatusLine(text: String(localized: "Couldn’t prepare the speech models. Downloaded files are kept."), tone: .error)
                LinkButton(title: showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .help(error)
            } else if model.modelsReady {
                StatusLine(text: String(localized: "Speech models ready. Recording can start right away."), tone: .ok)
            } else {
                StatusLine(text: stage, tone: .working)
            }
        } action: {
            Button { model.retryDownload() } label: {
                PrimarySlot(title: primaryTitle, enabled: model.downloadError != nil)
            }
            .buttonStyle(.plain)
            .disabled(model.downloadError == nil)
            if showDetails, let error = model.downloadError {
                Text(verbatim: error).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(t.muted(0.7)).lineLimit(2).textSelection(.enabled)
            }
        }
        .onAppear { model.startDownload() }
    }

    private var primaryTitle: String {
        if model.downloadError != nil { return String(localized: "Try again") }
        return model.modelsReady ? String(localized: "Models ready") : String(localized: "Preparing…")
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            Text(verbatim: stage).murFont(14, weight: .semibold).foregroundStyle(t.ink).lineLimit(1)
            Spacer(minLength: 0)
            if model.modelsReady {
                Text(verbatim: "✓").murFont(13, weight: .bold).foregroundStyle(t.ok).accessibilityHidden(true)
            } else if let fraction = model.preparationProgress?.fraction {
                Text(verbatim: "\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Mur.accent)
            } else if model.downloadError == nil {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) { progressBar.offset(y: 8) }
        .padding(.top, 10).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(t.line(0.07)).frame(height: 1) }
    }

    /// Indeterminate work shows no bar: it never fakes forward motion.
    @ViewBuilder private var progressBar: some View {
        let fraction = model.modelsReady ? 1 : model.preparationProgress?.fraction
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.line(0.1))
                Capsule().fill(model.modelsReady ? AnyShapeStyle(t.ok) : AnyShapeStyle(Mur.accent))
                    .frame(width: max(0, min(1, fraction ?? 0)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .opacity(fraction == nil ? 0 : 1)
    }

    private func modelRow(_ name: LocalizedStringKey, _ use: LocalizedStringKey, last: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).murFont(13.5, weight: .semibold).foregroundStyle(t.ink)
            Text(use).murFont(12).foregroundStyle(t.muted(0.62)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(t.line(0.07)).frame(height: 1) } }
    }
}
