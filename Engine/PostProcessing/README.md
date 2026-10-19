# MurmurPostProcessing

Local implementation of MurmurCore's provider-independent `TranscriptEditing`
contract. It accepts text, a detected language and an optional model ID. It does
not receive audio, open a microphone or upload text. RecordingSession composes
Whisper LID with this editor and final translation for macOS/iOS.

The model catalog includes custom MLX T5 providers for Russian SAGE 95M/820M,
Qwen3.5 2B, LFM2.5 2.6B, LFM2.5 1.2B Instruct and Gemma 4 E2B. Automatic selection
uses language coverage, available memory/platform and published specialist results;
it is not a complete task-specific quality ranking. Text is processed in bounded
sections with a fresh chat history and no tools. Empty, truncated and malformed
responses, changes to numeric tokens or substantive changes to URLs/emails fail the optional pass. Reasoning is
removed before the final output is validated. RecordingSession preserves original
ASR on failure and makes the original transcript available when edits succeed.

## Model verification

`text-edit-probe` runs a JSON fixture file through the same editor. Its JSON output
includes the actual model, output/error and wall time (first request includes model
download/load). It does not score accuracy or claim that alternative valid
punctuation is wrong. Use Release and a compiled MLX Metal resource bundle for real
inference; pure Swift tests do not establish device latency or semantic quality.

```sh
swift run -c release --package-path Engine/PostProcessing text-edit-probe \
  Engine/PostProcessing/Qualification/smoke.json qwen35
```

The ten curated smoke fixtures check Russian, Finnish, English and French, clean
text, numbers/names and dictated instructions. They are not a held-out benchmark.
Fresh model and language-specialist research is in
[the comparison](Qualification/MODELS.md).

A cloud or specialized T5 editor can implement `TranscriptEditing`; callers do
not need to change microphone capture, Whisper detection or transcript persistence.
SAGE is implemented and checked against Transformers. Cloud implementation and
qualification of Ahma/Luth are not included here.
