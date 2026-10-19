# Local and cloud provider routing

macOS and iOS share `ProviderRecordingSession` over the existing recording
lifecycle. Settings → Providers stores named connections and models separately
for live ASR, accurate ASR, final text correction and translation. Local is the
default. Dictator and Deepgram offer streaming/file ASR; OpenAI file ASR uses
API keys. OpenAI and Anthropic edit/translate text. macOS also offers official
ChatGPT plan sign-in for text operations; iOS sign-in is not implemented.

Dictator BYOK uses the user's key directly, with no account login or temporary
key issuance. The server determines translation access and billing. The optional
older Dictator account flow below remains separate; new provider selections take
priority for dictation. Keyboard and Safari extensions remain local.

For Dictator, enter the gateway base URL (for example,
`https://dictator-gateway-1281256944.europe-west1.run.app`). The client appends
`/v1/stream` for live dictation and `/v1/audio/transcriptions` for uploaded audio.
Pasted operation URLs and a trailing `/v1` are normalized to the gateway base,
including connections saved before this normalization was added.

Hybrid can combine a local fast draft with cloud phrase refinement, or cloud live
ASR with a separately selected accurate model. Closed audio ranges are refined
while capture continues; the remaining phrase finishes after release. One
microphone owns capture. After recognition, Whisper determines the language and
the enabled corrector receives the full final text (bounded contextual windows
for long recordings). Cloud translation runs after correction, once per final
text, instead of billing every live revision.

Shared vendor code comes from the public SwiftPM package
[bshk-app/ai-providers-swift](https://github.com/bshk-app/ai-providers-swift),
version `0.1.x`. There is no copied client source in this module. Update that
repository and the package version range rather than vendoring another snapshot.

## Existing optional Dictator account integration

The main iOS app can consume the same organization credit balance as the Dictator
website. On-device processing remains the default. This module adds no purchase
flow, web checkout link, StoreKit or RevenueCat dependency.

## Use in the app

1. Open Settings → Processing → Cloud account and sign in to an existing invited
   account. Email/password supports authenticator, explicitly requested email
   codes and backup codes. Completed bearer sessions are stored in Keychain.
2. Select Cloud under Processing. The setting discloses audio/text upload and
   credit consumption before starting an operation.
3. Start a voice note, explicitly transcribe an imported file, or translate text.
   The account screen displays available and reserved credits from the existing
   organization wallet. A web purchase does not grant credits again at sign-in.
4. Return to On device to use local models without a cloud account.

Cloud applies to the main app, including explicitly started conversation/file
transcription. Keyboard, Safari and selected-text translation extensions remain
local. A watch file received in cloud mode waits for an explicit foreground start.

The server controls translation languages, limits and tariffs. Translation is
available only when the service has configured and validated those rates
and language pairs. Photo OCR stays on device; only recognized text is uploaded
when cloud translation is selected. Voice translation is selected before recording;
it translates final segments and preserves the original on translation failure.

## Boundaries and recovery

- The app contacts https://dictator.bshk.app for authentication, wallet and
  capabilities. SDK-issued temporary keys authorize processing at the discovered
  HTTPS gateway. No customer key is embedded in the app or persisted with a note.
- Microphone capture begins only after the cloud stream is ready. Readiness and
  finalization have bounded waits. Disconnects and an overflowing audio queue stop
  capture, retaining the WAV and received text for a deliberate later action.
- File uploads are serial PCM16 WAV chunks, capped by the server limit and current
  available balance, with each returned result checkpointed. Cancelled or failed
  paid operations are not automatically retried after interruption or app restart.
  A request may already have been charged if its result was lost in transit.
- Cloud notes contain generic mode labels; internal models/runtime IDs are not
  shown. Local notes keep their existing local-model metadata.
- Apple is linked only from an authenticated account. The native entitlement is
  present; signed device provisioning must include Sign in with Apple for
  app.bshk.murmur.ios. Actual Apple authorization needs device verification.

## SDK verification

The shared repository retains the service import provenance and documents its
BYOK extension. `swift test` there verifies authentication/transport with fake
credentials. `swift test --package-path Engine/Cloud` here verifies adapters,
timed phrase refinement, cancellation and final-text processing. No tests upload
user audio or trigger paid inference. The stream DTO carries server sample ranges,
so cloud latency does not shift saved audio positions.

## Verification

Core regression tests, SDK mock transport/authentication tests and cloud
transcript/billing-policy tests run without paid inference. The main app builds
for arm64 iOS Simulator; signed simulator UI checks cover cloud selection, login
and upload disclosure. An unsigned simulator build cannot validate Keychain.
Real microphone/cloud inference and native Apple authorization are separate device
checks; no additional paid GPU inference is included in this integration.

UI regression: launch a signed app with --ui-testing on a dedicated signed-out
simulator, then run `maestro --device <udid> test Applications/iOS/Tests/CloudIntegration.yaml`.
The flow changes processing mode and reads the login screen without paid requests.

The existing September App Store drafts describe a fully local app. They require
updated privacy declarations and copy before publishing this cloud-enabled build.
The main app now uses CloudResources/PrivacyInfo.xcprivacy; local extensions retain
the original manifest. The cloud manifest declares account identifiers/email,
retained ASR result text and billable operation metadata. Source audio is processed
for the request rather than archived; photo pixels remain on device. Field names
follow [Apple's privacy manifest reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).
