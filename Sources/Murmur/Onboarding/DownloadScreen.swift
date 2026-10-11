import MurmurKit
import SwiftUI

/// Presents actual shared preparation progress without assuming model sizes or lanes.
struct DownloadScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    private var stage: LocalizedStringKey {
        guard let progress = model.preparationProgress else { return "Preparing speech models…" }
        switch progress.stage {
        case .unloading: return "Freeing model memory…"
        case .speech: return "Preparing speech models…"
        case .translation: return "Preparing translation…"
        case .warmup: return "Warming up recognition…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Download")
                    .tracking(1.4).murFont(11, weight: .bold)
                    .foregroundStyle(Mur.accent)
                Text("Getting my voice ready")
                    .murFont(32, weight: .semibold, design: .serif)
                    .foregroundStyle(t.ink).padding(.top, 10)
                Text("Speech models download to your Mac and run locally. Preparation includes loading and warming up recognition.")
                    .murFont(14.5).lineSpacing(4)
                    .foregroundStyle(t.muted(0.66))
                    .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
            }

            preparationCard.padding(.top, 22)

            if model.modelsReady {
                doneBanner.padding(.top, 14)
            } else if let err = model.downloadError {
                errorBanner(err).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.startDownload() }   // download starts when this step is reached
    }

    private var preparationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(model.modelsReady ? "Recognition is ready" : stage)
                    .murFont(15, weight: .semibold).foregroundStyle(t.ink)
                Spacer()
                if model.modelsReady {
                    readyPill
                } else if let fraction = model.preparationProgress?.fraction {
                    Text(verbatim: "\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Mur.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if model.modelsReady {
                progressBar(fraction: 1, ready: true)
            } else if let fraction = model.preparationProgress?.fraction {
                progressBar(fraction: fraction, ready: false)
            }
        }
        .padding(16)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private func progressBar(fraction: Double, ready: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.line(0.1))
                Capsule().fill(ready ? AnyShapeStyle(t.ok) : AnyShapeStyle(Mur.accent))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 7)
    }

    private var readyPill: some View {
        HStack(spacing: 6) {
            Text(verbatim: "✓").font(.system(size: 12, weight: .bold)).accessibilityHidden(true)
            Text("Ready").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(t.ok)
        .padding(.horizontal, 13).padding(.vertical, 6)
        .background(t.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Done / error banners

    private var doneBanner: some View {
        HStack(spacing: 11) {
            Circle().fill(t.ok).frame(width: 22, height: 22)
                .overlay(Text(verbatim: "✓").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                .accessibilityHidden(true)   // decorative; the banner text carries the meaning
            Text("Recognition is ready on your Mac.")
                .murFont(13.5, weight: .medium).foregroundStyle(t.ink)
            Spacer(minLength: 0)
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(t.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(t.ok.opacity(0.3), lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The download hit a snag.")
                    .murFont(13.5, weight: .semibold).foregroundStyle(Mur.error)
                Text(verbatim: message)
                    .murFont(12.5).lineSpacing(2).foregroundStyle(t.muted(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { model.retryDownload() } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Mur.error)
                    .padding(.horizontal, 17).padding(.vertical, 9)
                    .background(Mur.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Mur.error, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(Mur.error.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mur.error.opacity(0.3), lineWidth: 1))
    }
}
