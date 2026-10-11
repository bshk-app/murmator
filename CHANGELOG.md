# Changelog

All notable changes to Murmur are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub Release
body. Publishing without a matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Rewrite those generated lines in the PR into concise prose a person should
read in an update panel before merging it.

## [0.6.0](https://github.com/bshk-app/murmur/compare/murmur-v0.5.0...murmur-v0.6.0) (2026-10-11)

### Added

- The Mac app is now called Murmator, with a refreshed icon and mascot choices.
  Existing settings and permissions carry over.
- See which model is in memory, follow loading progress, cancel preparation,
  and unload models while keeping their downloaded files for next time.
- Try Whistle, a small CPU recognition model, under Settings → Experimental
  for English in Fast mode. Nemotron remains the default. Whistle is still
  experimental and is not available for other languages or recognition modes.

### Fixed

- Model changes release the previous model before loading its replacement.
  When you switch several times, the last choice wins.
- The menu shows microphone startup separately and says Listening only after
  recording starts. Cancelling preparation does not start the microphone.
- Whistle can recover from repeated endings when finishing a phrase; a final
  that still fails is reported as an error instead of inserting draft text.

## [0.5.0](https://github.com/bshk-app/murmur/compare/murmur-v0.4.0...murmur-v0.5.0) (2026-10-10)

0.4.0 never went out as an update, so this release also brings what it added:
dictate in one language and paste in another, with the translation shown under
what you said; live captions that translate a talk as it is spoken; and an
optional, more careful translation of the finished text.

### Added

- While you dictate, the draft appears right at your cursor as if already
  typed, and Return puts the corrected text in its place.
- Tap right ⌘ to start dictating, then Return to insert or Esc to cancel. Or
  hold right ⌘ while you talk and let go to insert.
- Push-to-talk now defaults to ⌥Space, and Murmur warns you when macOS already
  uses that shortcut.
- The on-screen indicator is a small capsule that stays put while you speak.
- Live captions have their own window: put it on any display, restyle it, and
  start or stop captions from the menu.

### Fixed

- When an app is slow to paste, it gets your dictation, not whatever was on
  your clipboard before.
- If the live-dictation model on disk is damaged, Murmur downloads it again
  instead of quietly showing no draft.

### iPhone and Apple Watch

These reach the iPhone app separately, not through this update.

- Record voice notes on Apple Watch and get the text back.
- Translate text in photos.
- Translate to and from Arabic offline; translated web pages switch to
  right-to-left.
- Dictate in Catalan, Norwegian, Icelandic, Serbian, Bosnian, Macedonian and
  Belarusian, and translate them offline to and from English.
- Optionally, speech is translated directly as you talk, where a direct model
  exists.
- Fewer recognition mistakes, especially in Finnish. The new model downloads
  once; delete "Previous speech recognition model" in Storage to free space.
- Tap the mascot and it reacts.
- Translating in other apps no longer runs out of memory, the Translate sheet
  shows progress while it checks your language packs, the last moment of a
  recording is no longer dropped, and the buttons and labels on a note match
  the rest of the app.

## [0.4.0](https://github.com/bshk-app/murmur/compare/murmur-v0.3.1...murmur-v0.4.0) (2026-09-05)


### Added

* **captions:** translate a talk as it is spoken ([010449e](https://github.com/bshk-app/murmur/commit/010449e423699c3a0b892778af7c4c0da74814e0))
* **dictation:** describe the session as a protocol ([c24ce43](https://github.com/bshk-app/murmur/commit/c24ce43e3002477f0aedc5113914b17709302eef))
* **engine:** make the engine configurable and report what the mic heard ([ffc19fe](https://github.com/bshk-app/murmur/commit/ffc19fe637b6f121b5a280fc9b4998ddaf03abb1))
* **hud:** show the translation under what you said ([3eee4b0](https://github.com/bshk-app/murmur/commit/3eee4b0992c6651b81cc9d1e6206ce1a2af8ceda))
* **translation:** a quality tier that translates the finished text ([d196202](https://github.com/bshk-app/murmur/commit/d1962021a9eac255e13e2502f591e4f851dd9aea))
* **translation:** dictate in one language, paste in another ([a415bd6](https://github.com/bshk-app/murmur/commit/a415bd6d4e057caa1f5921251d8ad421b00933d9))


### Fixed

* **analytics:** report the lane that ran, not the one that was requested ([7f04e8c](https://github.com/bshk-app/murmur/commit/7f04e8cbeaff12ad694cb66e48cb5b76d32ba901))
* **translation:** translate what you actually said, not what the menu says now ([27caa14](https://github.com/bshk-app/murmur/commit/27caa144061c8ad67555f9273db1b1daff417a95))


### Changed

* **dictation:** hold the session through the protocol ([ae1b066](https://github.com/bshk-app/murmur/commit/ae1b0660ff21b2ff3e6bc84f96662a8d5f5f9c32))

## [0.3.1](https://github.com/bshk-app/murmur/compare/murmur-v0.3.0...murmur-v0.3.1) (2026-08-25)


### Fixed

* **accessibility:** menu segments work with VoiceOver ([84a23e0](https://github.com/bshk-app/murmur/commit/84a23e08858be2234bcc9363ef6d9549f21dae35))
* **captions:** silence stops redrawing the overlay ([3c97bbf](https://github.com/bshk-app/murmur/commit/3c97bbf6902362a51667a67adb64ca9b081d69bb))

## [0.3.0](https://github.com/bshk-app/murmur/compare/murmur-v0.2.1...murmur-v0.3.0) (2026-08-25)

### Added

- Settings now decides what happens to recordings of your voice. Murmur can keep
  each dictation as an audio file so a bug can be reproduced from the real
  recording — off unless you ask for it, never uploaded, and now visible instead
  of hidden. You can see the files, delete them in one step, and what stays is
  the last twenty for seven days.

### Fixed

- The overlay leaves the moment you stop. Releasing the hotkey used to hold it a
  second longer, and stopping captions held it for four; now the panel goes as
  soon as your words have landed, and while the final wording is being decided it
  says so instead of pretending to still be listening.
- If the text could not be typed — no Accessibility permission, or a password
  field that refuses paste — the overlay stays and says which of the two it was,
  rather than disappearing with your sentence.

## [0.2.1](https://github.com/bshk-app/murmur/compare/murmur-v0.2.0...murmur-v0.2.1) (2026-08-24)

### Changed

- Nothing you can see: this build carries the same code as 0.2.0. The release
  pipeline now pins the speech engine to the exact revision it was tested
  against and restores the app's dependency lock, so every future build is
  reproducible from its tag.

## [0.2.0](https://github.com/bshk-app/murmur/compare/murmur-0.1.1...murmur-v0.2.0) (2026-08-24)

### Added

- Live captions now sharpen themselves phrase by phrase while you keep talking,
  instead of jumping at the end of a sentence.
- A "Dictate and send" shortcut types your words and presses Return for you.
- Choose your microphone in the menu instead of following the system default.

### Fixed

- The dictation overlay stays on the display you are working on, and no longer
  slides out of view during long dictations.
- A recording keeps the microphone and the start/stop gesture it began with,
  even if you change Settings while it runs.
- Text appears as soon as the fast model has it, and no longer takes seconds to
  land after you stop speaking.

## [Unreleased]

## [0.1.1] - 2026-06-27

### Changed

- Refreshed the distributed build and project presentation. No transcription
  behavior changed from 0.1.0.

[Unreleased]: https://github.com/bshk-app/murmur/compare/murmur-v0.1.1...HEAD
[0.1.1]: https://github.com/bshk-app/murmur/releases/tag/murmur-v0.1.1
