# Changelog

All notable changes to Murmur are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub Release
body. Publishing without a matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Rewrite those generated lines in the PR into concise prose a person should
read in an update panel before merging it.

## [0.7.0] - 2026-10-19

### Added

- Bring your own cloud providers for recognition, correction and translation.
  Choose a separate provider and model for each step, or keep it on this Mac.
  Connections include OpenAI, ChatGPT plan sign-in, Anthropic, Dictator,
  Deepgram, OpenRouter, Featherless and OpenAI-compatible servers. Available
  operations depend on the connection and model; no paid model is chosen for you.
- Search large model catalogs instead of scrolling through long menus.
- Set reasoning effort for a correction or translation model. OpenRouter can
  prefer low latency or a particular server, with an explicit fallback choice.
- Keep quick controls in the menu bar and use a separate window that stays open
  when you switch apps. Settings now has separate Models and Providers pages.
- Learn microphone selection, recognition modes, correction, translation and
  dictation at the caret through a step-by-step setup tour.

### Changed

- The optional corrector receives the finished text, including sentence context.
  Invalid model output keeps the original text. Long recordings are processed
  in bounded sections with neighbouring context.
- Press Return again while finishing to skip optional correction and insert the
  final recognized text. Recognition still finishes before anything is inserted.
- The mascot advises during errors or a long wait; ordinary dictation keeps its
  compact indicator and live draft.

### Fixed

- Fixed a crash after inserting dictated text when diagnostic stderr was no
  longer writable. Request diagnostics use system logging without transcript
  contents or API keys.
- Live recognition receives retained speech at the start of a phrase, keeping
  words that precede speech detection.
- Changing a connection during a recording keeps its original endpoint and key
  together. New settings apply to the next recording.
- Corrected model-list counts, stale search results and connection-check status.

Cloud correction quality depends on the selected model. This release does not
claim that a model benchmark or catalog entry guarantees correct recognition,
correction, account access or a particular response time.

## [0.6.0](https://github.com/bshk-app/murmur/compare/murmur-v0.5.0...murmur-v0.6.0) (2026-10-11)

Murmur is now called **Murmator**, with a new icon and a choice of mascots.
Your saved settings stay with you.

### Easier to get started

- See when speech recognition is loading, follow its progress, and cancel
  the wait if you change your mind.
- Free memory with **Unload** when you are done. Downloaded speech models
  stay on your Mac, ready to use again.
- Try **Whistle**, a smaller speech model for English in **Fast** mode, under
  **Settings → Experimental**. It is optional and experimental; Nemotron
  remains the default.

### Smoother dictation

- Switching recognition modes quickly now keeps your last choice.
- The menu says **Listening** only after the microphone has started.
  Cancelling loading does not turn the microphone on.
- Fixed a case where Whistle repeated the end of a sentence. If recognition
  cannot finish, the app shows an error so you can retry.

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
