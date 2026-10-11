#!/usr/bin/env bash
set -euo pipefail

# Recover the only non-atomic tail of a release: GitHub is already published but
# appcast/cask publication failed. No rebuild, codesign or notarization occurs;
# the exact public DMG + Zamok manifest are downloaded from the release.

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly TAG="${1:?usage: repair-release-publishing.sh TAG}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/murmur}"
CHANNEL="$(normalize_channel "${RELEASE_CHANNEL:-stable}")"
readonly CHANNEL
[[ "$CHANNEL" == "stable" ]] \
    || die "beta releases do not publish an appcast or cask; nothing to repair"
SHORT_VERSION="$(read_version)"
expected="$(release_tag "$SHORT_VERSION" "$CHANNEL")"
[[ "$TAG" == "$expected" ]] || die "tag $TAG does not match $expected from VERSION"

require_command gh
require_zamokctl
require_env SPARKLE_PUBLIC_ED_KEY
require_env TAP_GITHUB_TOKEN
reject_unresolved TAP_GITHUB_TOKEN
reject_unresolved SPARKLE_PRIVATE_ED_KEY
require_clean_pushed_tree

gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh is not authenticated for github.com"
is_draft="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft --jq .isDraft)"
[[ "$is_draft" == "false" ]] || die "$TAG is still a draft; run the normal release workflow"

work="$ROOT/out/repair-${SHORT_VERSION}"
rm -rf "$work"
mkdir -p "$work"
gh release download "$TAG" --repo "$REPOSITORY" \
    --pattern '*.dmg' --pattern 'manifest.json' --dir "$work"

dmg="$(find "$work" -maxdepth 1 -type f \( -name "Murmator-${SHORT_VERSION}.dmg" -o -name "Murmur-${SHORT_VERSION}.dmg" \) -print -quit)"
manifest="$work/manifest.json"
[[ -f "$dmg" ]] || die "$TAG has no Murmator or legacy Murmur DMG asset"
[[ -f "$manifest" ]] || die "$TAG has no Zamok manifest.json asset"

notes="$work/release-notes.md"
"$ROOT/scripts/extract-release-notes.sh" "$SHORT_VERSION" "$ROOT/CHANGELOG.md" > "$notes"
[[ -s "$notes" ]] || die "CHANGELOG has no notes for $SHORT_VERSION"

note "== repairing Sparkle appcast from the published DMG =="
"$ROOT/scripts/publish-appcast.sh" "$dmg" "$SHORT_VERSION" "$TAG" "$notes"
note "== repairing Homebrew cask from the published DMG =="
cask_metadata="$ROOT/Distribution/cask-murmur.json"
if [[ "$(basename "$dmg")" == "Murmur-${SHORT_VERSION}.dmg" ]]; then
    # Old immutable releases still contain Murmur.app.
    cask_metadata="$work/cask-legacy.json"
    jq '.name = "Murmur" | .appBundle = "Murmur.app"' \
        "$ROOT/Distribution/cask-murmur.json" > "$cask_metadata"
fi
CASK_METADATA="$cask_metadata" "$ROOT/scripts/publish-cask.sh" "$dmg" "$SHORT_VERSION" "$TAG"

printf 'Publishing repaired for %s.\n' "$TAG"
