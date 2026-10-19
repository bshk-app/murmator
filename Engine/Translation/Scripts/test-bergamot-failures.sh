#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
LIBRARY="${MURMUR_MT_LIBRARY:-$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework/macos-arm64/libmurmurmt.a}"
xcrun clang++ -std=c++17 -mmacosx-version-min=15.0 \
  -I "$ROOT/MurmurKit/Sources/CBergamot/include" \
  "$ROOT/Engine/Translation/Tests/bergamot-failure-smoke.cpp" "$LIBRARY" \
  -framework Accelerate -liconv -L/opt/homebrew/lib -lpcre2-8 -o "$WORK/smoke"
"$WORK/smoke" "$WORK/models" "$@"
