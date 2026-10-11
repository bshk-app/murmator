#!/usr/bin/env bash
set -euo pipefail

# One release body for local and CI use:
#
#   unsigned Tuist build -> zamokctl codesign -> notarize -> staple -> DMG
#                        -> GitHub Release -> signed legacy appcast -> cask
#
# Run through `task release`, which resolves any av:// references in .env.

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly PUBLISH_MODE="${PUBLISH-1}"
readonly OUT_DIR="${ROOT}/out"
readonly APP_PATH="${ROOT}/build/Murmator.app"
readonly PLIST_BUDDY=/usr/libexec/PlistBuddy

require_publish_mode "$PUBLISH_MODE"

require_zamokctl
require_command security
require_command gh
require_command shasum
[[ -x "$PLIST_BUDDY" ]] || die "missing $PLIST_BUDDY"

CHANNEL="$(normalize_channel "${RELEASE_CHANNEL:-stable}")"
readonly CHANNEL
if [[ "$PUBLISH_MODE" == "1" && "$CHANNEL" == "stable" ]]; then
    require_env SPARKLE_PUBLIC_ED_KEY
    reject_unresolved SPARKLE_PRIVATE_ED_KEY
    require_env TAP_GITHUB_TOKEN
    reject_unresolved TAP_GITHUB_TOKEN
fi

SHORT_VERSION="$(read_version)"
[[ -f "$ROOT/BUILD_NUMBER_BASE" ]] || die "BUILD_NUMBER_BASE is missing"
BUILD_NUMBER="$("$ROOT/scripts/build-number.sh")"
if [[ "$PUBLISH_MODE" == "1" && "$CHANNEL" == "stable" ]]; then
    assert_build_number_increases "$BUILD_NUMBER" \
        "${GITHUB_RELEASE_REPOSITORY:-bshk-app/murmur}" "${APPCAST_BRANCH:-main}"
fi

require_clean_pushed_tree
if [[ "$PUBLISH_MODE" == "1" && "$CHANNEL" == "stable" ]]; then
    tap_repository="${HOMEBREW_TAP:-bshk-app/homebrew-tap}"
    verify_github_repo_write "$TAP_GITHUB_TOKEN" "$tap_repository"
    export TAP_WRITE_VERIFIED_REPOSITORY="$tap_repository"
fi
if [[ "$PUBLISH_MODE" == "1" && "$CHANNEL" == "stable" ]]; then
    sparkle_key_probe="$(mktemp)"
    trap 'rm -f "$sparkle_key_probe"' EXIT
    "$ROOT/scripts/export-sparkle-key.sh" "$sparkle_key_probe"
    rm -f "$sparkle_key_probe"
    trap - EXIT
fi

SIGNING_SHA1="${RELEASE_SIGNING_IDENTITY_SHA1:-}"
if [[ -z "$SIGNING_SHA1" ]]; then
    require_env RELEASE_DEVELOPER_ID_APPLICATION
    SIGNING_SHA1="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | grep -F "$RELEASE_DEVELOPER_ID_APPLICATION" \
            | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40}).*/\1/' \
            | head -1
    )"
fi
[[ -n "$SIGNING_SHA1" ]] \
    || die "could not resolve a Developer ID SHA1; set RELEASE_SIGNING_IDENTITY_SHA1"

notary_args=()
if [[ -n "${RELEASE_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--notary-profile "$RELEASE_NOTARY_PROFILE")
else
    require_env NOTARY_KEY_PATH
    require_env NOTARY_KEY_ID
    require_env NOTARY_ISSUER
    [[ -f "$NOTARY_KEY_PATH" ]] || die "notary key not found at $NOTARY_KEY_PATH"
    notary_args=(
        --notary-api-key "$NOTARY_KEY_PATH"
        --notary-key-id "$NOTARY_KEY_ID"
        --notary-issuer "$NOTARY_ISSUER"
    )
fi

mkdir -p "$OUT_DIR"
notes_file="$OUT_DIR/release-notes.md"
"$ROOT/scripts/extract-release-notes.sh" "$SHORT_VERSION" "$ROOT/CHANGELOG.md" > "$notes_file"
if [[ ! -s "$notes_file" && "$PUBLISH_MODE" == "1" ]]; then
    die "CHANGELOG.md has no '## [$SHORT_VERSION]' section"
fi

note "== GitHub release preflight =="
env PUBLISH="$PUBLISH_MODE" RELEASE_CHANNEL="$CHANNEL" \
    "$ROOT/scripts/publish-github-release.sh" --preflight "$SHORT_VERSION"

note "== staging unsigned Murmator.app =="
APP_VERSION="$SHORT_VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT/scripts/stage-murmur-app.sh" "$APP_PATH"
[[ -d "$APP_PATH" ]] || die "staging produced no bundle at $APP_PATH"

plist="$APP_PATH/Contents/Info.plist"
staged_short="$($PLIST_BUDDY -c 'Print CFBundleShortVersionString' "$plist")"
staged_build="$($PLIST_BUDDY -c 'Print CFBundleVersion' "$plist")"
staged_sparkle_key="$($PLIST_BUDDY -c 'Print SUPublicEDKey' "$plist")"
[[ "$staged_short" == "$SHORT_VERSION" ]] || die "staged version mismatch"
[[ "$staged_build" == "$BUILD_NUMBER" ]] || die "staged build mismatch"
[[ "$staged_sparkle_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
    || die "SPARKLE_PUBLIC_ED_KEY does not match the key baked into Murmator.app"

cat >&2 <<INFO

== releasing ==
  version   $staged_short ($staged_build)
  channel   $CHANNEL
  identity  $SIGNING_SHA1

INFO

rm -f "$OUT_DIR"/*.dmg "$OUT_DIR"/*/*.dmg 2>/dev/null || true
zamokctl package \
    --input "$APP_PATH" \
    --output-dir "$OUT_DIR" \
    --signing-identity-sha1 "$SIGNING_SHA1" \
    --entitlements "$ROOT/Murmur.entitlements" \
    "${notary_args[@]}" \
    --format dmg

dmg_path="$(find "$OUT_DIR" -maxdepth 3 -type f -name "Murmator-${staged_short}.dmg" -print -quit)"
[[ -n "$dmg_path" && -f "$dmg_path" ]] \
    || die "zamokctl package produced no Murmator-${staged_short}.dmg under $OUT_DIR"
package_manifest="$(find "$(dirname "$dmg_path")" -maxdepth 1 -type f -name manifest.json -print -quit)"
[[ -n "$package_manifest" && -f "$package_manifest" ]] \
    || die "zamokctl package produced no manifest.json beside the DMG"

manifest="$OUT_DIR/github-release-manifest"
"$ROOT/scripts/write-release-manifest.sh" \
    "$dmg_path" "$notes_file" "$staged_short" "$staged_build" \
    "$CHANNEL" "$PUBLISH_MODE" "$manifest"

note "== publishing GitHub Release =="
env PUBLISH="$PUBLISH_MODE" RELEASE_CHANNEL="$CHANNEL" \
    "$ROOT/scripts/publish-github-release.sh" \
        "$dmg_path" "$notes_file" "$staged_short" "$manifest" "$package_manifest"

if [[ "$PUBLISH_MODE" == "1" && "$CHANNEL" == "stable" ]]; then
    tag="$(release_tag "$staged_short" "$CHANNEL")"
    note "== publishing Sparkle appcast =="
    "$ROOT/scripts/publish-appcast.sh" \
        "$dmg_path" "$staged_short" "$tag" "$notes_file"
    note "== publishing Homebrew cask =="
    "$ROOT/scripts/publish-cask.sh" "$dmg_path" "$staged_short" "$tag"
elif [[ "$PUBLISH_MODE" == "1" ]]; then
    note "note: beta release is GitHub-only; stable appcast and cask unchanged"
else
    note "note: PUBLISH=0 — draft only; appcast and cask unchanged"
fi

printf '\nReleased Murmator %s (%s) to the %s channel.\n' \
    "$staged_short" "$staged_build" "$CHANNEL"
