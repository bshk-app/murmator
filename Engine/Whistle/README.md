# Whistle CPU for macOS

Native Swift/Accelerate recognition, promoted from the measured Whistle prototype.
The package has no MLX, Python or C++ dependency. The macOS app exposes it as an
**opt-in English Fast candidate** in Settings → Experimental speech recognition.
Choose English and Fast in the menu. Other profiles use the existing backend.
The four-clip pilot preserves quality. A later phrase in a repeated-speech test
exposed sensitivity to the first-two-second normalization. Finalization now has
one recovery attempt using whole-phrase statistics and full encoder context.
Broader long-session reliability remains a qualification gate; this backend is
not qualified as a default. Unresolved finals abort delivery and allow Retry.

App plumbing lives in `Engine/Speech/WhistleSpeechSession` and `Engine/Session`:
16 kHz mono microphone conversion, WAV recording when enabled, a ten-second
admission bound, CPU Core ML Silero VAD, pause/30-second phrase boundaries,
replaceable previews, and final segments passed to the usual transcript/translation
owner. No intermediate words are committed by prefix agreement. A failed or
token-limited final reports an error; it does not promote a preview.

The archive downloads on first use to Application Support/MurMur/Whistle. Its size
and SHA-256 are checked on every load; downloads use unique staging files and are
published only after verification. `WhistleAssets` pins revision
`ca5287601bef25af26dcf2e1b2bdc0843a7c19e5` of
[Cactus-Compute/whistle](https://huggingface.co/Cactus-Compute/whistle/tree/ca5287601bef25af26dcf2e1b2bdc0843a7c19e5).
Only the 16,919,407-byte `whistle.cact` is required. The model card declares Apache-2.0;
see [model attribution](NOTICE.md). No upstream inference binary ships in this path.

## Runtime

Load one `WhistleRecognizer` on a serial executor and call `makeUtterance()` per
phrase. `append` accepts finite mono 16 kHz Float PCM; `finish` drains the encoder
and returns an EOS-complete result. If the first final reaches the token limit or
repeats a 4...16-token cycle twice and starts it again, it recomputes all retained
PCM with whole-phrase normalization, bidirectional encoder attention, fresh
encoder state, and a fresh decoder. There is at most one retry; the final still
requires the model's EOS. The recovery decoder uses no repetition suppression,
so it can recognize actual repeated speech. First finals without the cycle signal
are unchanged. A cycle signal requests recomputation; it never truncates
the text or supplies EOS. Full-context work is bounded to 375 rows / 30 seconds.
`WhistleCompute.finalRetries` records recovery attempts. Empty EOF produces empty
text. An utterance is limited to 30 seconds, and cannot be reused after EOF or a
compute failure.

The first preview needs 2 seconds of phrase audio. It uses an isolated, full-context
encoder pass and a fresh decoder with at most 32 tokens; it never updates the
persistent streaming cache or confirms words. The regular cached preview schedule
still starts at 2.8 seconds, including right context, then needs 1.28 seconds of new
PCM. Shorter 1.28-second prefixes were faster but produced less useful first words
on the pilot. Token budgets grow with encoded audio, from
32 to at most 160; the final budget is 318. The capture adapter suppresses obsolete
previews when more than 384 ms of audio is pending, retaining all accepted PCM and
always doing phrase finals. Cancellation is checked between frontend tiles,
encoder layers and decoder tokens.

Encoder chunks commit 16 frames with 16 lookahead and retain 64 K/V plus four
convolution rows per layer. Decoder state resets per draft. CQ2/CQ4 weights stay
packed; A8 numerics use Float arrays. Frontend still recomputes available prefixes.

Silero consumes 256 ms chunks. The adapter keeps 768 ms of preroll, ends after
768 ms of silence, and resets ASR caches at each phrase. A continuous phrase is
split before 30 seconds; this safety boundary can split a word. The native
unsegmented pilot's quality is not a claim about arbitrary segmented recordings.

## Validation and reproduction

```sh
swift build -c release --package-path Engine/Whistle
WHISTLE_WEIGHTS=/path/to/whistle.cact \
WHISTLE_FIXTURES=$PWD/Prototypes/WhistleCPU/.fixtures \
WHISTLE_AUDIO_FIXTURES=$PWD/Prototypes/WhistleCPU/.audio-fixtures \
  swift test -c release --package-path Engine/Whistle

Engine/Whistle/.build/release/whistle-bench \
  --weights /path/to/whistle.cact --pcm /path/to/mono-16k.f32 \
  --output /tmp/whistle-paced.json --paced true
```

`whistle-bench` is a paced PCM measurement of one utterance, excluding microphone,
VAD and translation. It reports all previews, EOS/tokens, compute by stage, input
lag, queue peak, first preview, finalization and peak RSS. Use `--paced false` for
an unpaced throughput control. Do not benchmark while compiling dependencies.

The full app session can be exercised without microphone permission:

```sh
swift build -c release --package-path Engine/Session --product session-probe
MURMUR_WHISTLE_CPU=1 Engine/Session/.build/release/session-probe \
  --wav /path/to/speech.wav --source en --mode fast --target none \
  --models-root /tmp/whistle-models --translation-root /tmp/whistle-translation \
  --output /tmp/whistle-session.json
```

This includes VAD, segmentation and RecordingSession transcript orchestration.
`--seconds 90` repeats input with two-second silent gaps for a long-session check.
The flag affects only this probe, not application preferences. The boundary
regressions are also covered without pacing by
`RecognizerTests.testShiftedPhraseCompletesInsteadOfRepeating` and
`testEOSDoesNotConfirmRepeatedEnding`: they derive the exact failing
612 ms and 712 ms / 18.688 s windows from the pinned pilot PCM.

The original [research controls](../../Prototypes/WhistleCPU/README.md) still cover
effective weights, teacher logits, CPU/GPU matrices, exact final IDs and cache work.
Broader held-out quality, less powerful Macs, physical microphone/device changes
and user-facing latency still need qualification before a default rollout.
