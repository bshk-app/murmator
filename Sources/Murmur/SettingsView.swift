import AppKit
import KeyboardShortcuts
import MurmurKit
import SwiftUI

/// Murmur's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    let dictation: DictationController
    @AppStorage(WhistleSetting.key) private var whistleFastEnabled = false
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false
    @AppStorage(RightCommandTrigger.key) private var rightCommand = true
    @AppStorage(HUDStyle.defaultsKey) private var hudStyle: HUDStyle = .caret
    @AppStorage(DictationSession.recordUtterancesKey) private var recordUtterances = false
    @State private var confirmingDelete = false
    /// Counted when the pane appears and after a delete, never inside `body`:
    /// touching the filesystem on every re-render would run it on each animation
    /// frame of the switch above it.
    @State private var recordingCount = 0
    /// Whether macOS answers to the same chords. Checked when the pane shows,
    /// when a shortcut changes, and when Murmur comes back to the front.
    @State private var dictateClash: SystemShortcutClash?
    @State private var sendClash: SystemShortcutClash?

    var body: some View {
        Form {
            Section {
                MascotStylePicker()
            } header: {
                Text("Mascot")
            }

            Section {
                Toggle("Dictate with right ⌘", isOn: $rightCommand)
            } header: {
                Text("Right ⌘")
            } footer: {
                Text("Tap right ⌘ and speak, then press Return to insert the text or Esc to throw it away. Press Return twice to insert and send. Or hold right ⌘ while you speak and let go to insert. Needs Accessibility, like typing does.")
            }

            Section {
                KeyboardShortcuts.Recorder("Push-to-talk:", name: .dictate) { _ in refreshClashes() }
                clashNote(dictateClash, name: .dictate)
                KeyboardShortcuts.Recorder("Dictate and send:", name: .dictateAndSend) { _ in refreshClashes() }
                clashNote(sendClash, name: .dictateAndSend)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold a shortcut to dictate; release to finish. “Dictate and send” also presses Return, which sends the message in most chats. Leave it empty if you mostly dictate into editors, where Return would just break the line.")
            }

            Section {
                Picker("While you speak:", selection: $hudStyle) {
                    Text("At the caret").tag(HUDStyle.caret)
                    Text("Compact").tag(HUDStyle.compact)
                    Text("Full").tag(HUDStyle.full)
                }
            } header: {
                Text("On-screen pill")
            } footer: {
                Text("At the caret draws your words where they will be inserted, as they are recognised; nothing is typed until you finish. Apps that don't say where their caret is get the compact capsule. Compact is a small capsule at the bottom of the screen that only shows Murmator is listening. Full shows your words in a larger pill at the bottom of the screen.")
            }

            Section {
                Picker("English Fast model", selection: $whistleFastEnabled) {
                    Text("Nemotron (GPU)").tag(false)
                    Text("Whistle (CPU)").tag(true)
                }
                .accessibilityIdentifier("englishFastModelPicker")
                .disabled(!dictation.canChangeModels)
                .onChange(of: whistleFastEnabled) { _, _ in dictation.prepareCurrentMode() }
            } header: {
                Text("Experimental speech recognition")
            } footer: {
                Text("Whistle runs on this Mac and downloads a 17 MB model on first use. Choose English and Fast in the menu to use it.")
            }

            Section {
                Toggle("Share anonymous usage & crash reports", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in
                        AnalyticsConsent.set(on)
                    }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Helps fix bugs and improve Murmator. Only anonymous events and errors are sent — never your audio or transcripts. Dictation runs fully on-device either way.")
            }

            Section {
                // Turning it off only stops new recordings. Deleting is a separate,
                // confirmed action: a switch must not destroy someone's audio as a
                // side effect of being flipped.
                Toggle("Keep recordings of what I dictate", isOn: $recordUtterances)
                HStack {
                    Button("Show Recordings") {
                        NSWorkspace.shared.open(DiagnosticRecordings.directory())
                    }
                    Button("Delete Recordings Now…") { confirmingDelete = true }
                    .disabled(recordingCount == 0)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Saves your dictated audio as WAV files on this Mac so a bug can be reproduced from the real recording. Off by default. Nothing is uploaded. The last \(DiagnosticRecordings.keepNewest) recordings are kept for \(Int(DiagnosticRecordings.maxAge / 86_400)) days, then deleted automatically.")
            }
            .confirmationDialog(
                "Delete \(recordingCount) recording\(recordingCount == 1 ? "" : "s")?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    DiagnosticRecordings.deleteAll()
                    recordingCount = DiagnosticRecordings.count()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved audio of what you dictated. It cannot be undone.")
            }
        }
        .onAppear {
            recordingCount = DiagnosticRecordings.count()
            refreshClashes()
        }
        // Back from System Settings, where the macOS shortcut may just have
        // been turned off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClashes()
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 300)
    }

    private func refreshClashes() {
        dictateClash = SystemShortcuts.clash(for: .dictate)
        sendClash = SystemShortcuts.clash(for: .dictateAndSend)
    }

    @ViewBuilder
    private func clashNote(_ clash: SystemShortcutClash?, name: KeyboardShortcuts.Name) -> some View {
        if let clash, let chord = KeyboardShortcuts.getShortcut(for: name)?.description {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(SystemShortcuts.warning(clash, chord: chord))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                Button("Open Keyboard Settings…") { NSWorkspace.shared.open(SystemShortcuts.settingsURL) }
            }
        }
    }
}
