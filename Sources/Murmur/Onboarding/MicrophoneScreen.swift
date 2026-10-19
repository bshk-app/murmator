@preconcurrency import AVFoundation
import MurmurKit
import Observation
import SwiftUI

/// Step 2 — Microphone: access, the input list, and a level test. The test opens
/// only the input and records nothing.
struct MicrophoneScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var test: MicLevelMonitor { model.micTest }

    var body: some View {
        StepPage(step: .microphone,
                 title: "Pick the microphone I listen to",
                 lede: "Choose an input and say a few words. The bars move only when sound actually reaches Murmator.") {
            Text("Nothing is recorded during the microphone test.").murFont(12.5).foregroundStyle(t.muted(0.62))
        } controls: {
            Text("Microphone access").murFont(13, weight: .semibold).foregroundStyle(t.ink)
            accessChip
            if !model.flow.micGranted {
                Button { model.requestMic() } label: {
                    Text(model.micDenied ? "Open System Settings…" : "Allow")
                        .murFont(12, weight: .semibold).foregroundStyle(t.ink)
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(t.line(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        } stage: {
            HStack(spacing: 14) {
                deviceList
                levelCard
            }
        } status: {
            StatusLine(text: statusText, tone: statusTone)
        } action: {
            Button { model.toggleMicTest() } label: {
                PrimarySlot(title: test.running ? String(localized: "Stop test") : String(localized: "Test microphone"),
                            enabled: model.flow.micGranted, live: test.running)
            }
            .buttonStyle(.plain)
            .disabled(!model.flow.micGranted)
        }
        .onAppear { model.refreshPermissions(); model.refreshMicrophones() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            model.refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            model.refreshMicrophones()
        }
        .onDisappear { test.stop() }
    }

    private var accessChip: some View {
        let granted = model.flow.micGranted
        return Text(granted ? "Allowed" : (model.micDenied ? "Off" : "Not asked yet"))
            .murFont(11.5, weight: .semibold)
            .foregroundStyle(granted ? t.ok : Mur.error)
            .padding(.horizontal, 8).frame(height: 22)
            .background((granted ? t.ok : Mur.error).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: input list

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input device").murFont(12, weight: .semibold).foregroundStyle(t.muted(0.7))
                .padding(.horizontal, 6).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    deviceRow(uid: MicrophoneSetting.systemDefaultUID,
                              name: String(localized: "System default"),
                              detail: AVCaptureDevice.default(for: .audio)?.localizedName)
                    ForEach(model.microphones) { device in
                        deviceRow(uid: device.uid, name: device.name, detail: nil)
                    }
                }
            }
            .scrollIndicators(.never)
            if let lost = model.disconnectedMicrophone {
                Text("\(lost) disconnected. System default is used until you pick another input.")
                    .murFont(11.5).foregroundStyle(Mur.error).lineLimit(2)
                    .padding(.horizontal, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private func deviceRow(uid: String, name: String, detail: String?) -> some View {
        let selected = model.microphoneUID == uid
        return Button { model.microphoneUID = uid } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(selected ? Mur.accent : t.muted(0.4), lineWidth: selected ? 4.5 : 1.5)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name).murFont(13, weight: .semibold).foregroundStyle(t.ink).lineLimit(1)
                    if let detail {
                        Text("Now: \(detail)").murFont(11.5).foregroundStyle(t.muted(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Mur.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: level

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Input level · \(model.microphoneName)").murFont(12, weight: .semibold)
                .foregroundStyle(t.muted(0.7)).lineLimit(1)
            LevelMeter(level: test.running ? test.level : 0)
                .frame(height: 44)
            Text(verdict).murFont(13, weight: .medium).foregroundStyle(verdictColor).lineLimit(2)
            Spacer(minLength: 0)
            Text("Your choice here is the same Microphone setting as in the menu bar.")
                .murFont(11.5).foregroundStyle(t.muted(0.6)).lineLimit(2)
        }
        .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private var verdict: LocalizedStringKey {
        if model.micDenied { return "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone." }
        if test.failed { return "This input didn’t open. Pick another one." }
        if test.heard { return "Hearing you clearly." }
        if test.running { return "Listening for your voice…" }
        return "Press Test microphone and say a few words."
    }

    private var verdictColor: Color {
        if model.micDenied || test.failed { return Mur.error }
        return test.heard ? t.ok : t.muted(0.7)
    }

    private var statusText: String {
        if model.micDenied { return String(localized: "Microphone access is off.") }
        if test.running { return String(localized: "Microphone open · \(model.microphoneName)") }
        return String(localized: "Selected: \(model.microphoneName) · microphone closed")
    }

    private var statusTone: StatusTone {
        if model.micDenied || test.failed { return .error }
        return test.running ? .live : .neutral
    }
}

/// 24 bars filled up to the measured level.
private struct LevelMeter: View {
    let level: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = OnTheme(scheme)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0 ..< 24, id: \.self) { i in
                let on = Double(i) / 24 < level
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? (i > 19 ? Mur.error : Mur.accent) : t.line(0.1))
                    .frame(height: CGFloat(8 + (i % 5) * 7 + (on ? 6 : 0)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100))%")
    }
}

/// Opens one input for metering only — no file, no recognition. Uses the
/// capture connection's own power level, so nothing processes the samples.
@MainActor
@Observable
final class MicLevelMonitor {
    /// 0…1, from the channel's average power.
    private(set) var level: Double = 0
    /// Sound above the speech threshold for about 0.3 s.
    private(set) var heard = false
    private(set) var running = false
    private(set) var failed = false

    @ObservationIgnored private var capture: AVCaptureSession?
    @ObservationIgnored private var output: AVCaptureAudioDataOutput?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loudTicks = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "murmur.onboarding.mic-test")

    /// `uid` nil means the system default input.
    func start(uid: String?) {
        stop()
        failed = false; heard = false; loudTicks = 0
        let device = uid.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { failed = true; return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { failed = true; return }
        session.addInput(input)
        session.addOutput(output)
        capture = session
        self.output = output
        running = true
        queue.async { session.startRunning() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let capture { queue.async { capture.stopRunning() } }
        capture = nil; output = nil
        running = false
        level = 0
    }

    private func sample() {
        guard let channels = output?.connection(with: .audio)?.audioChannels, !channels.isEmpty else { return }
        // dBFS → 0…1 over a -60…0 dB window.
        let power = channels.map(\.averagePowerLevel).max() ?? -160
        level = max(0, min(1, Double(power + 60) / 60))
        loudTicks = level > 0.35 ? loudTicks + 1 : 0
        if loudTicks >= 3 { heard = true }
    }
}
