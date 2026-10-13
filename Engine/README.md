# MurMur engine

Reusable local Swift packages shared by the macOS compatibility facade, MurMur Lab, and the separate iOS application.

| Product | Responsibility |
| --- | --- |
| `MurmurCore` | Caption snapshots, correction windows, speech boundaries, language/model choices, atomic note storage. Foundation only. |
| `MurmurSpeech` | Microphone capture, Silero VAD, live ASR, independent Core ML correctors, model preparation and replay. |
| `MurmurTranslation` | Mozilla preview, strict OPUS correction, verified downloads and translation sessions. |
| `MurmurSession` | Shared foreground preparation, capture lifecycle, corrected transcript and translation orchestration for iOS and macOS. |
| `MurmurCaptions` | macOS captions band: layout, appearance, smoothly scrolling transcript and translation tracks. Takes settings as values; where the band goes and how settings persist stay with the app. Used by the Murmur captions overlay and by Kafedra's stage. |

Consumers depend on the products directly. `MurmurKit` re-exports them for existing macOS callers; the mobile applications do not depend on the desktop app or compile its files.

## Foreground recording

Both apps use `RecordingSession` from `MurmurSession`; see [its lifecycle contract](Session/README.md). Apps own UI, permissions and persistence destinations. Speech/translation policy is implemented once in the package. Experimental direct translation, background keyboard sessions and file import retain their specialized lower-level APIs.

## Speech

Create a `SpeechSession` with an explicit `modelsRoot`, load the desired lanes, then attach `onSnapshot`, `onError`, and optionally `onModelEvent`/capture callbacks before starting. Call `stop()` to finish a note; call `close()` before replacing a session to drain work and release models. Independent hybrid mode keeps the live model on MLX/GPU and the complete corrector on Core ML CPU/ANE. Correction input is bounded by the existing speech boundary and context policies.

Advanced staged assets use `modelsRoot/ASRModels` and `modelsRoot/CoreMLModels`. Downloaded fast/GigaAM/Parakeet assets retain the Hugging Face SDK cache. Models are not embedded in the source package.

The minimal vendored MLX Audio source contains the tested checkpoint fixes; see `Speech/Vendor/mlx-audio-swift/PROVENANCE.md`. Build MLX consumers with Xcode on Apple Silicon so Metal resources are packaged.

## Translation

`TranslationSession.prepare` checks both preview and quality routes. Completed phrases receive OPUS results asynchronously; `finish` requests strict OPUS translation of the final text. Missing quality assets produce an error, not a silent preview fallback.

`Translation/Artifacts/MurmurMT.xcframework` contains arm64 macOS and physical-iOS static libraries. There is currently **no simulator slice**. Native sources remain in `../MurmurKit/Sources/CBergamot`; the existing desktop `build-bergamot.sh` and `Translation/Patches/build-translation.sh` build their platform archives. This native build-source migration is still outstanding; consuming the checked-in package artifact requires neither script nor the lab app. Keep the upstream native licenses with distributed artifacts.

## Checks

```sh
swift test --package-path Engine/Core
swift test --package-path Engine/Captions
bash Applications/iOS/build.sh CODE_SIGNING_ALLOWED=NO
bash Prototypes/iOS/build.sh CODE_SIGNING_ALLOWED=NO
```

Device validation is needed for model loading, Metal/ANE concurrency, thermal behavior, and microphone routing. Core unit tests do not substitute for those checks.
