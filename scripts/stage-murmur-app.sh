#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly OUTPUT="${1:-${ROOT}/build/Murmator.app}"
readonly SHORT_VERSION="${APP_VERSION:-$(read_version)}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-$("$ROOT/scripts/build-number.sh")}"
readonly DERIVED_DATA="${MURMUR_DERIVED_DATA:-${ROOT}/build/DerivedData}"
readonly PLIST_BUDDY=/usr/libexec/PlistBuddy

require_command tuist
require_command xcodebuild
require_command ditto
require_command shasum
require_command jq
[[ -x "$PLIST_BUDDY" ]] || die "missing $PLIST_BUDDY"
[[ -s "$ROOT/.package.resolved" ]] || die ".package.resolved is missing"
dependency_hash="$(jq -cS '.pins | sort_by(.identity)' "$ROOT/.package.resolved" | shasum -a 256)"
require_semver APP_VERSION "$SHORT_VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
    || die "BUILD_NUMBER must be an integer, got: $BUILD_NUMBER"

rm -rf "$DERIVED_DATA" "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

printf '== generating Murmator %s (%s) ==\n' "$SHORT_VERSION" "$BUILD_NUMBER" >&2
(
    cd "$ROOT"
    TUIST_APP_VERSION="$SHORT_VERSION" \
    TUIST_APP_BUILD="$BUILD_NUMBER" \
        tuist generate --no-open

    # Tuist links the workspace lock to .package.resolved. Refuse an unexpected
    # re-resolution instead of shipping a graph different from the tested one.
    [[ "$(jq -cS '.pins | sort_by(.identity)' "$ROOT/.package.resolved" | shasum -a 256)" == "$dependency_hash" ]] \
        || die "Tuist changed dependency versions; qualify and commit the new lock first"

    TUIST_APP_VERSION="$SHORT_VERSION" \
    TUIST_APP_BUILD="$BUILD_NUMBER" \
        xcodebuild \
            -workspace Murmur.xcworkspace \
            -scheme Murmur \
            -configuration Release \
            -derivedDataPath "$DERIVED_DATA" \
            -destination 'generic/platform=macOS' \
            -onlyUsePackageVersionsFromResolvedFile \
            ARCHS=arm64 \
            ONLY_ACTIVE_ARCH=YES \
            SWIFT_ENABLE_EXPLICIT_MODULES=NO \
            CODE_SIGNING_ALLOWED=NO \
            build
)

readonly BUILT_APP="${DERIVED_DATA}/Build/Products/Release/Murmator.app"
[[ -d "$BUILT_APP" ]] || die "build produced no app at $BUILT_APP"
ditto "$BUILT_APP" "$OUTPUT"

readonly PLIST="${OUTPUT}/Contents/Info.plist"
readonly EXECUTABLE="${OUTPUT}/Contents/MacOS/Murmator"
readonly METALLIB="${OUTPUT}/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[[ -f "$PLIST" ]] || die "staged app has no Info.plist"
[[ -x "$EXECUTABLE" ]] || die "staged app has no executable"
[[ -f "$METALLIB" ]] || die "staged app has no MLX Metal library"

staged_version="$($PLIST_BUDDY -c 'Print CFBundleShortVersionString' "$PLIST")"
staged_build="$($PLIST_BUDDY -c 'Print CFBundleVersion' "$PLIST")"
[[ "$staged_version" == "$SHORT_VERSION" ]] \
    || die "staged marketing version is $staged_version, expected $SHORT_VERSION"
[[ "$staged_build" == "$BUILD_NUMBER" ]] \
    || die "staged build number is $staged_build, expected $BUILD_NUMBER"

printf 'Staged: %s (%s) at %s\n' "$staged_version" "$staged_build" "$OUTPUT"
