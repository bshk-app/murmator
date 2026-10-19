# /// script
# requires-python = ">=3.10"
# dependencies = ["transformers==4.39.0", "torch==2.14.1", "numpy"]
# ///
"""Compare SAGE MLX output with the original checkpoint's HF implementation.

uv run reference_sage.py /path/to/checkpoint smoke.json
No microphone, remote inference or model download. Symlink original tokenizer
files into a temporary directory to avoid using generated MLX tokenizer metadata.
"""
import json
from pathlib import Path
import sys
import tempfile

import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

root = Path(sys.argv[1]).resolve()
fixtures = json.loads(Path(sys.argv[2]).read_text())
torch.set_num_threads(4)
with tempfile.TemporaryDirectory(prefix="sage-reference-") as directory:
    reference = Path(directory)
    for name in ["config.json", "model.safetensors", "tokenizer_config.json",
                 "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt"]:
        (reference / name).symlink_to((root / name).resolve())
    tokenizer = AutoTokenizer.from_pretrained(reference, local_files_only=True)
    model = AutoModelForSeq2SeqLM.from_pretrained(reference, local_files_only=True).eval()
    rows = []
    for fixture in fixtures:
        if fixture["language"] != "ru":
            continue
        inputs = tokenizer(fixture["text"], return_tensors="pt")
        with torch.inference_mode():
            output = model.generate(**inputs, do_sample=False,
                                    max_new_tokens=inputs.input_ids.shape[1] * 2 + 32)
        rows.append({"id": fixture["id"], "input_ids": inputs.input_ids[0].tolist(),
                     "output": tokenizer.decode(output[0], skip_special_tokens=True)})
print(json.dumps(rows, ensure_ascii=False, indent=2))
