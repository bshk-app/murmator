"""Paced native and optional app-session pilot, with pinned input provenance."""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--decoder-fixtures", type=Path, required=True)
    parser.add_argument("--scorer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--session-probe", type=Path)
    parser.add_argument("--wav-root", type=Path)
    args = parser.parse_args()
    if args.session_probe and not args.wav_root:
        parser.error("--session-probe needs --wav-root")
    manifest = json.loads((args.fixtures / "audio-manifest.json").read_text())
    oracle = json.loads((args.decoder_fixtures / "manifest.json").read_text())
    gold = {row["filename"]: row for row in oracle["rows"]}
    assert sha(args.weights) == manifest["weights_sha256"]
    spec = importlib.util.spec_from_file_location("whistle_corpus_scorer", args.scorer)
    scoring = importlib.util.module_from_spec(spec)
    saved_argv = sys.argv
    try:
        sys.argv = [str(args.scorer)]
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(scoring)
    finally:
        sys.argv = saved_argv
    normalize, distance = scoring.normalize, scoring.distance
    root = Path(__file__).resolve().parents[3]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "scope": "M1 Max paced native utterance pilot; optional VAD/app transcript session",
        "caveat": "Single runs on an active workstation; no thermal/frequency control. Same four English pilot clips, not held-out qualification or microphone testing.",
        "weights_sha256": sha(args.weights),
        "binary_sha256": sha(args.binary),
        "audio_manifest_sha256": sha(args.fixtures / "audio-manifest.json"),
        "decoder_manifest_sha256": sha(args.decoder_fixtures / "manifest.json"),
        "scorer_sha256": sha(args.scorer),
        "evaluation_script_sha256": sha(__file__),
        "corpus_revision": manifest["corpus_revision"],
        "source_sha256": {
            str(file.relative_to(root)): sha(file)
            for file in sorted((root / "Engine/Whistle/Sources").glob("**/*.swift"))
        },
        "rows": [],
    }
    if args.session_probe:
        report["session_probe_sha256"] = sha(args.session_probe)
        for pattern in [
            "Engine/Speech/Sources/MurmurSpeech/Whistle*.swift",
            "Engine/Session/Sources/MurmurSession/*.swift",
            "Engine/Core/Sources/MurmurCore/SpeechRecognitionProfile.swift",
        ]:
            for file in root.glob(pattern):
                report["source_sha256"][str(file.relative_to(root))] = sha(file)
    for row in manifest["rows"]:
        pcm = args.fixtures / row["pcm"]["file"]
        assert sha(pcm) == row["pcm"]["sha256"]
        output = args.output.parent / (row["filename"] + ".native.json")
        subprocess.run(
            [
                str(args.binary.resolve()),
                "--weights",
                str(args.weights.resolve()),
                "--pcm",
                str(pcm.resolve()),
                "--output",
                str(output.resolve()),
                "--paced",
                "true",
            ],
            check=True,
        )
        native = json.loads(output.read_text())
        assert native["pcmSHA256"] == row["pcm"]["sha256"]
        reference = normalize(row["reference"]).split()
        measured = {
            "filename": row["filename"],
            "reference": row["reference"],
            "reference_words": len(reference),
            "native": native,
            "final_ids_equal": native["final"]["ids"] == gold[row["filename"]]["ids"],
            "final_text_equal": native["final"]["text"]
            == gold[row["filename"]]["hypothesis"],
            "word_errors": distance(
                reference, normalize(native["final"]["text"]).split()
            ),
        }
        if args.session_probe:
            wav = args.wav_root / row["filename"]
            assert sha(wav) == row["wav_sha256"]
            session_output = args.output.parent / (row["filename"] + ".session.json")
            subprocess.run(
                [
                    str(args.session_probe.resolve()),
                    "--wav",
                    str(wav.resolve()),
                    "--source",
                    "en",
                    "--mode",
                    "fast",
                    "--target",
                    "none",
                    "--models-root",
                    "/tmp/murmur-whistle-models",
                    "--translation-root",
                    "/tmp/murmur-whistle-translation",
                    "--output",
                    str(session_output.resolve()),
                ],
                env={**os.environ, "MURMUR_WHISTLE_CPU": "1"},
                check=True,
            )
            session = json.loads(session_output.read_text())
            measured["session"] = session
            measured["session_word_errors"] = distance(
                reference, normalize(session["finalText"]).split()
            )
        report["rows"].append(measured)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(
            row["filename"],
            "exact=",
            measured["final_ids_equal"],
            "errors=",
            measured["word_errors"],
            flush=True,
        )
    rows = report["rows"]
    words = sum(row["reference_words"] for row in rows)
    compute = sum(
        sum(
            row["native"]["compute"][key]
            for key in ["frontendSeconds", "encoderSeconds", "decoderSeconds"]
        )
        for row in rows
    )
    audio = sum(row["native"]["audioSeconds"] for row in rows)
    report.update(
        {
            "completed": len(rows),
            "audio_seconds": audio,
            "compute_seconds": compute,
            "compute_per_audio": compute / audio,
            "word_errors": sum(row["word_errors"] for row in rows),
            "reference_words": words,
            "wer": sum(row["word_errors"] for row in rows) / words,
            "all_final_ids_equal": all(row["final_ids_equal"] for row in rows),
            "all_final_text_equal": all(row["final_text_equal"] for row in rows),
            "all_final_eos": all(
                row["native"]["final"]["endedWithEOS"] for row in rows
            ),
            "peak_rss_bytes": max(row["native"]["peakRSSBytes"] for row in rows),
            "max_finalization_seconds": max(
                row["native"]["finalizationSeconds"] for row in rows
            ),
            "max_queue_seconds": max(
                row["native"]["peakQueuedAudioSeconds"] for row in rows
            ),
        }
    )
    if args.session_probe:
        report["session_word_errors"] = sum(row["session_word_errors"] for row in rows)
        report["session_wer"] = report["session_word_errors"] / words
        report["all_sessions_completed"] = all(
            row["session"]["status"] == "completed" and not row["session"]["failures"]
            for row in rows
        )
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(
        json.dumps(
            {
                key: value
                for key, value in report.items()
                if key not in ("rows", "source_sha256")
            },
            indent=2,
        )
    )
    return (
        0
        if report["all_final_ids_equal"]
        and report["all_final_eos"]
        and report.get("all_sessions_completed", True)
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())
