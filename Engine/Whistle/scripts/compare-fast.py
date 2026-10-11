"""Sequential paired macOS app-session comparison, using the unchanged scorer."""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import platform
import statistics
import subprocess
import sys
from pathlib import Path


def sha(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("probe", "corpus", "wav-root", "output"):
        p.add_argument("--" + name, type=Path, required=True)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[3]
    a.output.mkdir(parents=True, exist_ok=True)
    corpus = json.loads(a.corpus.read_text())
    clips = [c for c in corpus["clips"] if c["language"] == "en"]
    assert len(clips) == 4
    scorer_path = root / "Prototypes/iOS/scripts/score-corpus.py"
    spec = importlib.util.spec_from_file_location("scorer", scorer_path)
    scorer = importlib.util.module_from_spec(spec)
    saved = sys.argv
    try:
        sys.argv = [str(scorer_path)]
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(scorer)
    finally:
        sys.argv = saved
    nemotron = (
        Path.home()
        / ".cache/huggingface/hub/mlx-audio/mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit"
    )
    whistle = (
        Path.home()
        / "Library/Application Support/MurMur/Whistle/ca5287601bef25af26dcf2e1b2bdc0843a7c19e5/whistle.cact"
    )
    models = {
        "nemotron": {
            "revision": "7279359e4481b5e9e185a318bd618e429c6d86cd",
            "execution": "MLX GPU; app Fast; 160 ms stream chunks",
            "bytes": sum(
                (nemotron / n).stat().st_size
                for n in ["config.json", "vocab.txt", "model.safetensors"]
            ),
            "filesSHA256": {
                n: sha(nemotron / n)
                for n in ["config.json", "vocab.txt", "model.safetensors"]
            },
        },
        "whistle": {
            "revision": "ca5287601bef25af26dcf2e1b2bdc0843a7c19e5",
            "execution": "Swift/Accelerate CPU; CPU Core ML VAD; EOS recovery enabled",
            "bytes": whistle.stat().st_size,
            "filesSHA256": {"whistle.cact": sha(whistle)},
        },
    }
    assert (
        models["nemotron"]["filesSHA256"]["model.safetensors"]
        == "a64a4da048e7d28dde4cd4ff61ce59308a63314bb5563e73e06c24aae50ea941"
    )
    assert (
        models["whistle"]["filesSHA256"]["whistle.cact"]
        == "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    )
    report = {
        "scope": "same Mac, English Fast, translation disabled, 1536-sample / 96 ms paced input; shared RecordingSession and backend-specific app VAD/segmentation",
        "caveat": "One paired run per input on an active workstation; no thermal/frequency control. Four reused pilot clips, not held-out accuracy, microphone or energy measurement. Compute is elapsed time inside speech adapter calls including VAD/GPU waits, not CPU time.",
        "platform": platform.platform(),
        "hardware": subprocess.check_output(
            ["sysctl", "-n", "hw.model"], text=True
        ).strip(),
        "models": models,
        "binarySHA256": sha(a.probe),
        "scorerSHA256": sha(scorer_path),
        "runnerSHA256": sha(__file__),
        "corpusManifestSHA256": sha(a.corpus),
        "corpusRevision": corpus["revision"],
        "rows": [],
    }
    patterns = [
        "Engine/Whistle/Sources/**/*.swift",
        "Engine/Session/Sources/**/*.swift",
        "Engine/Core/Sources/MurmurCore/*.swift",
        "Engine/Speech/Sources/MurmurSpeech/*.swift",
        "Engine/Speech/Vendor/mlx-audio-swift/Sources/MLXAudioSTT/Models/NemotronASR/*.swift",
    ]
    report["sourcesSHA256"] = {
        str(f.relative_to(root)): sha(f)
        for pattern in patterns
        for f in sorted(root.glob(pattern))
    }

    def save():
        (a.output / "comparison.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )

    for index, clip in enumerate(clips + [clips[0]]):
        long = index == len(clips)
        wav = a.wav_root / clip["filename"]
        assert sha(wav) == clip["wavSHA256"]
        ref = " ".join([clip["reference"]] * 4) if long else clip["reference"]
        reference = scorer.normalize(ref).split()
        pair = {
            "name": "four-cycles" if long else clip["filename"],
            "group": "long" if long else "pilot",
            "reference": ref,
            "referenceWords": len(reference),
            "wavSHA256": sha(wav),
            "backends": {},
        }
        order = ["nemotron", "whistle"] if index % 2 == 0 else ["whistle", "nemotron"]
        pair["runOrder"] = order
        for backend in order:
            name = backend + "-" + pair["name"].removesuffix(".wav")
            output = a.output / (name + ".json")
            command = [
                str(a.probe.resolve()),
                "--wav",
                str(wav.resolve()),
                "--source",
                "en",
                "--mode",
                "fast",
                "--target",
                "none",
                "--models-root",
                "/tmp/murmur-fast-compare-models",
                "--translation-root",
                "/tmp/murmur-fast-compare-translation",
                "--output",
                str(output.resolve()),
            ]
            if long:
                command += ["--seconds", "86.64"]
            env = dict(os.environ)
            env.pop("MURMUR_WHISTLE_CPU", None)
            if backend == "whistle":
                env["MURMUR_WHISTLE_CPU"] = "1"
            result = subprocess.run(
                command, check=False, env=env, cwd=root, capture_output=True, text=True
            )
            (a.output / (name + ".log")).write_text(result.stdout + result.stderr)
            measured = json.loads(output.read_text())
            want = (
                "whistle-swift-cpu"
                if backend == "whistle"
                else "nemotron-3.5-asr-streaming-0.6b-8bit"
            )
            assert measured["speechProfile"]["preview"] == want
            assert measured["speechProfile"]["final"] == "disabled"
            assert (
                result.returncode == 0
                and measured["status"] == "completed"
                and not measured["failures"]
            ), name
            assert measured["latestSpeechTelemetry"]["pendingAudioChunks"] == 0
            measured["wordEdits"] = scorer.distance(
                reference, scorer.normalize(measured["finalText"]).split()
            )
            measured["referenceWords"] = len(reference)
            measured["WER"] = measured["wordEdits"] / len(reference)
            measured["CER"] = scorer.distance(
                list(scorer.normalize(ref).replace(" ", "")),
                list(scorer.normalize(measured["finalText"]).replace(" ", "")),
            ) / len(scorer.normalize(ref).replace(" ", ""))
            measured["normalizedHypothesis"] = scorer.normalize(measured["finalText"])
            measured["reportFile"] = output.name
            measured["reportSHA256"] = sha(output)
            pair["backends"][backend] = measured
            print(
                json.dumps(
                    {
                        "input": pair["name"],
                        "backend": backend,
                        "errors": measured["wordEdits"],
                        "words": len(reference),
                        "firstText": measured.get("firstSnapshotSeconds"),
                        "compute": measured["speechComputeSeconds"],
                        "peakMiB": measured["processPeakRSSBytes"] / 2**20,
                    }
                ),
                flush=True,
            )
        assert (
            pair["backends"]["nemotron"]["replayAudioSHA256"]
            == pair["backends"]["whistle"]["replayAudioSHA256"]
        )
        report["rows"].append(pair)
        save()
    report["summary"] = {}
    for backend in models:
        rows = [r["backends"][backend] for r in report["rows"] if r["group"] == "pilot"]
        words = sum(r["referenceWords"] for r in rows)
        audio = sum(r["audioSeconds"] for r in rows)
        compute = sum(r["speechComputeSeconds"] for r in rows)
        report["summary"][backend] = {
            "words": words,
            "audioSeconds": audio,
            "errors": sum(r["wordEdits"] for r in rows),
            "WER": sum(r["wordEdits"] for r in rows) / words,
            "computeSeconds": compute,
            "computePerAudio": compute / audio,
            "CPUSeconds": sum(r["replayCPUSeconds"] for r in rows),
            "firstTextMedian": statistics.median(
                r["firstSnapshotSeconds"] for r in rows
            ),
            "firstTextRange": [
                min(r["firstSnapshotSeconds"] for r in rows),
                max(r["firstSnapshotSeconds"] for r in rows),
            ],
            "tailMedian": statistics.median(
                r["speechReplayWallSeconds"] - r["audioSeconds"] for r in rows
            ),
            "tailMax": max(
                r["speechReplayWallSeconds"] - r["audioSeconds"] for r in rows
            ),
            "peakRSSBytes": max(r["processPeakRSSBytes"] for r in rows),
            "sampledPeakFootprintBytes": max(
                r["latestSpeechTelemetry"]["sampledPeakProcessFootprintBytes"]
                for r in rows
            ),
            "peakPendingChunks": max(
                r["latestSpeechTelemetry"]["peakPendingAudioChunks"] for r in rows
            ),
        }
    save()
    print(json.dumps(report["summary"], ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
