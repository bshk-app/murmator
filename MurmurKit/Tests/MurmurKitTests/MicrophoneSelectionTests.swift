@testable import MurmurSpeech
import CoreAudio
import XCTest
@testable import MurmurKit

final class MicrophoneSelectionTests: XCTestCase {
    private let builtIn = MicrophoneDevice(
        audioID: AudioDeviceID(7), name: "MacBook Microphone", uid: "builtin-mic"
    )
    private let usb = MicrophoneDevice(
        audioID: AudioDeviceID(42), name: "Studio USB", uid: "usb-mic"
    )

    /// Core Audio IDs can change after reconnect; the persisted UID chooses the
    /// current ID of the same physical device.
    func test_preferred_uid_routes_to_its_current_audio_id() throws {
        var routed: AudioDeviceID?

        let didRoute = try AudioInputDevices.route(
            preferredUID: usb.uid,
            devices: [builtIn, usb],
            apply: { routed = $0 }
        )

        XCTAssertTrue(didRoute)
        XCTAssertEqual(routed, usb.audioID)
    }

    /// "System Default" is represented by the empty persisted value. Doing
    /// nothing is important: AVAudioEngine then follows the current Core Audio
    /// default rather than pinning whichever default happened to exist earlier.
    func test_system_default_does_not_pin_a_device() throws {
        var routed: AudioDeviceID?

        let didRoute = try AudioInputDevices.route(
            preferredUID: MicrophoneSetting.systemDefaultUID,
            devices: [builtIn, usb],
            apply: { routed = $0 }
        )

        XCTAssertFalse(didRoute)
        XCTAssertNil(routed)
    }

    /// A selected USB/Bluetooth mic can disappear between opening the menu and
    /// pressing the hotkey. Missing means fallback to Core Audio's system default,
    /// never a failed recording.
    func test_missing_preferred_device_falls_back_to_system_default() throws {
        var routed: AudioDeviceID?

        let didRoute = try AudioInputDevices.route(
            preferredUID: "unplugged-mic",
            devices: [builtIn],
            apply: { routed = $0 }
        )

        XCTAssertFalse(didRoute)
        XCTAssertNil(routed)
    }

    /// The picker also falls back visibly when a saved device is no longer in the
    /// current catalog, instead of holding an invalid selection with no label.
    func test_picker_sanitizes_a_missing_uid() {
        XCTAssertEqual(
            AudioInputDevices.sanitizedUID("unplugged-mic", devices: [builtIn, usb]),
            MicrophoneSetting.systemDefaultUID
        )
        XCTAssertEqual(AudioInputDevices.sanitizedUID(usb.uid, devices: [builtIn, usb]), usb.uid)
    }

    /// Stable UID identity and deterministic sorting keep SwiftUI Picker rows from
    /// jumping when Core Audio returns devices in a different order.
    func test_picker_devices_sort_by_name_then_uid() {
        let sameName = MicrophoneDevice(audioID: 99, name: usb.name, uid: "z-usb")

        XCTAssertEqual(
            AudioInputDevices.sorted([sameName, usb, builtIn]).map(\.uid),
            [builtIn.uid, usb.uid, sameName.uid]
        )
    }

    /// Every app capture path reads the same persisted UID — main dictation,
    /// captions, and Setup Tour — while the empty value remains System Default.
    func test_current_uid_reads_the_persisted_selection() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: MicrophoneSetting.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: MicrophoneSetting.defaultsKey)
            } else {
                defaults.removeObject(forKey: MicrophoneSetting.defaultsKey)
            }
        }

        defaults.set(usb.uid, forKey: MicrophoneSetting.defaultsKey)
        XCTAssertEqual(MicrophoneSetting.currentUID, usb.uid)

        defaults.set(MicrophoneSetting.systemDefaultUID, forKey: MicrophoneSetting.defaultsKey)
        XCTAssertNil(MicrophoneSetting.currentUID)
    }
}
