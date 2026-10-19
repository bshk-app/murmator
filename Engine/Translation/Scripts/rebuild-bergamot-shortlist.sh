#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BERG_SOURCE="${BERG_SOURCE:-/Volumes/DATA/bergamot-arm64/src}"
BERG_MAC_BUILD="${BERG_MAC_BUILD:-/Volumes/DATA/bergamot-arm64/build15}"
BERG_IOS_BUILD="${BERG_IOS_BUILD:-$ROOT/Prototypes/iOS/build/bergamot-device}"
MAR_SOURCE="$BERG_SOURCE/3rd_party/marian-dev/src"
ARTIFACT="$ROOT/Engine/Translation/Artifacts/MurmurMT.xcframework"
WORK="$(mktemp -d)"
# Patch a build copy. The external Bergamot checkout stays unchanged.
cp "$MAR_SOURCE/data/shortlist.cpp" "$WORK/shortlist.cpp"
(cd "$WORK" && patch --forward shortlist.cpp < "$ROOT/Engine/Translation/Patches/marian-shortlist-empty-tail.patch")
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  case "$slice" in
    macos-arm64) sdk=macosx; target=arm64-apple-macos15.0; build="$BERG_MAC_BUILD";;
    ios-arm64) sdk=iphoneos; target=arm64-apple-ios18.0; build="$BERG_IOS_BUILD";;
    ios-arm64-simulator) sdk=iphonesimulator; target=arm64-apple-ios18.0-simulator; build="$BERG_IOS_BUILD";;
  esac
  mkdir -p "$WORK/$slice"
  xcrun --sdk "$sdk" clang++ -std=c++17 -O3 -fno-strict-aliasing -Wno-deprecated-declarations -Wno-unused-value -Wno-unused-result -Wno-unknown-pragmas -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -c "$WORK/shortlist.cpp" -o "$WORK/$slice/shortlist.cpp.o" \
    -DARM -DBLAS_FOUND=1 -DCOMPILE_CPU=1 -DCPUINFO_SUPPORTED_PLATFORM=1 -DFMA -DSSE -DUSE_PTHREADS -DUSE_SENTENCEPIECE -D_USE_INTERNAL_STRING_VIEW \
    -I"$MAR_SOURCE" -I"$MAR_SOURCE/data" -I"$MAR_SOURCE/3rd_party" \
    -I"$MAR_SOURCE/3rd_party/sentencepiece" -I"$MAR_SOURCE/3rd_party/spdlog/include" \
    -I"$build/3rd_party/marian-dev/src/3rd_party"
  cp "$ARTIFACT/$slice/libmurmurmt.a" "$WORK/$slice/libmurmurmt.a"
  xcrun ar -r "$WORK/$slice/libmurmurmt.a" "$WORK/$slice/shortlist.cpp.o"
  xcrun ranlib "$WORK/$slice/libmurmurmt.a"
done
for slice in macos-arm64 ios-arm64 ios-arm64-simulator; do
  cp "$WORK/$slice/libmurmurmt.a" "$ARTIFACT/$slice/libmurmurmt.a"
done
printf 'Shortlist boundary fix built for all slices. Evidence: %s\n' "$WORK"
