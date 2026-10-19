#!/bin/bash
# Replace only the Bergamot C shim; preserve the compiled engines and CT2 shim.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SHIM="$ROOT/MurmurKit/Sources/CBergamot"
BERG_SOURCE="${BERG_SOURCE:-/Volumes/DATA/bergamot-arm64/src}"
BERG_MAC_BUILD="${BERG_MAC_BUILD:-/Volumes/DATA/bergamot-arm64/build15}"
BERG_IOS_BUILD="${BERG_IOS_BUILD:-$ROOT/Prototypes/iOS/build/bergamot-device}"
ARTIFACT="$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework"
WORK="$(mktemp -d)"
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  case "$slice" in
    macos-arm64) sdk=macosx; target=arm64-apple-macos15.0; build="$BERG_MAC_BUILD";;
    ios-arm64) sdk=iphoneos; target=arm64-apple-ios18.0; build="$BERG_IOS_BUILD";;
    ios-arm64-simulator) sdk=iphonesimulator; target=arm64-apple-ios18.0-simulator; build="$BERG_IOS_BUILD";;
  esac
  mkdir -p "$WORK/$slice"
  xcrun --sdk "$sdk" clang++ -std=c++17 -O2 -Wno-deprecated-declarations -Wno-unused-value -Wno-unused-result -Wno-unknown-pragmas -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -c \
    "$SHIM/murmur_mt.cpp" -o "$WORK/$slice/murmur_mt.o" \
    -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DCPUINFO_SUPPORTED_PLATFORM=1 \
    -DFMA -DNDEBUG -DSSE -DUSE_PTHREADS -DUSE_SENTENCEPIECE -D_USE_INTERNAL_STRING_VIEW \
    -I"$SHIM" -I"$BERG_SOURCE" -I"$BERG_SOURCE/src" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src/3rd_party" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src/3rd_party/spdlog/include" \
    -I"$BERG_SOURCE/3rd_party/marian-dev/src/3rd_party/sentencepiece" \
    -I"$BERG_SOURCE/3rd_party/ssplit-cpp/src/ssplit" \
    -I"$BERG_SOURCE/3rd_party/ssplit-cpp/src/3rd-party/CLI11" \
    -I"$build/3rd_party/marian-dev/src/3rd_party"
  cp "$ARTIFACT/$slice/libmurmurmt.a" "$WORK/$slice/libmurmurmt.a"
  xcrun ar -r "$WORK/$slice/libmurmurmt.a" "$WORK/$slice/murmur_mt.o"
  xcrun ranlib "$WORK/$slice/libmurmurmt.a"
done
# Publish only after all slices compile successfully.
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  cp "$WORK/$slice/libmurmurmt.a" "$ARTIFACT/$slice/libmurmurmt.a"
done
printf 'Bergamot shim rebuilt for all slices. Build evidence: %s\n' "$WORK"
