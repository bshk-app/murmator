# Local corrector qualification

Automatic routing is an initial deployment policy, not a task-specific quality
ranking. The implementation and pinned revisions live in `LocalTextModel`,
`LocalTranscriptEditor` and `SageTranscriptEditor`.

| Route | Initial choice |
|---|---|
| Russian on a Mac with at least 16 GB RAM | SAGE large, 820M |
| Russian on other supported devices | SAGE distilled, 95M |
| Languages covered by the compact LFM provider | LFM2.5 1.2B Instruct |
| Other languages | Qwen3.5 2B |

The picker also offers LFM2.5 2.6B and Gemma 4 E2B. Choosing a model does not
establish that it improves a particular dictation. Confirm spelling, negation,
names, numeric strings, references and preservation of already-correct text.
The output validator catches some malformed or excessive edits; passing it is
not a semantic-quality score.

`smoke.json` contains prepared synthetic examples, not private recordings or an
independent evaluation corpus. `reference_sage.py` compares the native SAGE
implementation with the original Transformers model using local checkpoints.
Use Release and a compiled MLX Metal resource bundle for native inference.

The corrector receives completed text. Ordinary dictation is one request;
long text uses bounded sentence-aligned windows with neighbouring context.
Provider failures and rejected edits preserve the finished original text.
Language detection and recognition quality require separate audio evaluation.

Model sources:
[SAGE 95M](https://huggingface.co/ai-forever/sage-fredt5-distilled-95m),
[SAGE large](https://huggingface.co/ai-forever/sage-fredt5-large),
[Qwen3.5](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit),
[LFM2.5 compact](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit),
[LFM2.5](https://huggingface.co/LiquidAI/LFM2.5-2.6B-MLX),
[Gemma 4](https://huggingface.co/mlx-community/gemma-4-E2B-it-4bit).
