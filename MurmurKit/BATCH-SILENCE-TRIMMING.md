# Batch silence trimming — issue #13

`TwoPassSession` now applies the stop-time policy to hybrid and accurate CLI
dictation. Silero scans 512-sample frames at 16 kHz. The batch window is the span
from the first to the last speech frame, plus 256 ms at each end. Interior pauses
are retained and the live chunks are forwarded unchanged. A partial final frame
is padded only for VAD; that padding never enters the batch model.

When VAD finds no speech, exact digital silence skips the batch. Other audio is
passed through unchanged until a microphone noise floor has been calibrated.
The comparison uses the maximum of the capture's peak RMS and the peak RMS of
512-sample frames. Double accumulation preserves very weak Float signals.
Model warm-up explicitly bypasses this policy so Parakeet still compiles its
kernels on the synthetic warm-up input.

The nonzero production floor remains **unconfigured**. The room-tone criterion
in [#13](https://github.com/bshk-app/murmator/issues/13) requires real background
noise and quiet/whispered speech recordings from the quietest supported microphone.
The local speech fixture is sufficient to verify VAD trimming, but cannot establish
that microphone's floor. Synthetic test floors are not calibration measurements.

Measure labelled 16 kHz mono captures with:

```sh
swift scripts/measure-batch-silence.swift \
  --microphone 'microphone model and gain' \
  --noise /path/to/room-tone.wav \
  --quiet-speech /path/to/quiet-speech.wav \
  --quiet-speech /path/to/whisper.wav > /tmp/batch-silence-calibration.json
```

The report identifies the recordings by SHA-256 and proposes the smallest Float
floor above all measured noise peaks only when it lies below every labelled quiet
speech peak. Overlapping recordings produce no candidate. Before enabling a
candidate, verify the microphone identity, gain, representative recordings and
`DictationSession.capturedPeak`; file measurements do not include the resampler's
capture-block peak. Until this evidence exists, keep the production floor at zero.

Regression coverage includes edge trimming, interior pauses, digital silence,
calibrated fixture room tone, VAD misses, very weak signals, partial frames,
capture peak propagation, live continuity and model warm-up. The optional local
Silero test uses cached weights and `Prototypes/iOS/Resources/smoke-ru.wav`.
