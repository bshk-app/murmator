#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

preflight=false
if [[ "${1:-}" == "--preflight" ]]; then
    preflight=true
    shift
    readonly SHORT_VERSION="${1:-$(read_version)}"
    readonly ARTIFACT=""
    readonly NOTES_FILE=""
    readonly MANIFEST=""
    readonly PACKAGE_MANIFEST=""
else
    readonly SHORT_VERSION="${3:-$(read_version)}"
    readonly ARTIFACT="${1:-$(find "$ROOT/out" -maxdepth 3 -type f -name "Murmator-${SHORT_VERSION}.dmg" -print -quit 2>/dev/null || true)}"
    readonly NOTES_FILE="${2:-${ROOT}/out/release-notes.md}"
    readonly MANIFEST="${4:-${ROOT}/out/github-release-manifest}"
    readonly PACKAGE_MANIFEST="${5:-$(find "$(dirname "${ARTIFACT:-$ROOT/out/x}")" -maxdepth 1 -type f -name manifest.json -print -quit 2>/dev/null || true)}"
fi

readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/murmur}"
CHANNEL="$(normalize_channel "${RELEASE_CHANNEL:-stable}")"
readonly CHANNEL
readonly PUBLISH_MODE="${PUBLISH-1}"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
readonly HEAD_SHA

require_publish_mode "$PUBLISH_MODE"

command -v gh >/dev/null 2>&1 || die "gh is required. Install it and run gh auth login."
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh is not authenticated for github.com"
gh api "repos/${REPOSITORY}/commits/${HEAD_SHA}" --silent >/dev/null \
    || die "$HEAD_SHA is not present in $REPOSITORY"

# No working-tree check here: by this point the build has run and generated
# files exist. release.sh gates cleanliness before anything is compiled, and
# provenance is enforced below by the tag/HEAD match and the manifest hashes.

tag="$(release_tag "$SHORT_VERSION" "$CHANNEL")"
if [[ "$CHANNEL" == "stable" ]]; then
    title="Murmator ${SHORT_VERSION}"
    prerelease=false
    latest=true
else
    title="Murmator ${SHORT_VERSION} (${CHANNEL})"
    prerelease=true
    latest=false
fi

draft=false
if [[ "$PUBLISH_MODE" == "0" ]]; then
    draft=true
    latest=false
fi

# gh has no "does this exist" query: HTTP 404 means absent, and any other
# failure must stop the release instead of being mistaken for absence.
GH_ERRORS="$(mktemp)"
readonly GH_ERRORS
trap 'rm -f "$GH_ERRORS"' EXIT
PROBE_OUT=""
gh_probe() {
    local subject="$1"
    shift
    if PROBE_OUT="$("$@" 2>"$GH_ERRORS")"; then
        return 0
    fi
    local text
    text="$(<"$GH_ERRORS")"
    case "$text" in
        *"HTTP 404"*|*"not found"*|*"Not Found"*) return 1 ;;
        *) die "could not inspect $subject: $text" ;;
    esac
}

if gh_probe "GitHub tag $tag" \
    gh api "repos/${REPOSITORY}/git/ref/tags/${tag}" --jq '.object.type + " " + .object.sha'
then
    read -r object_type object_sha <<< "$PROBE_OUT"
    if [[ "$object_type" == "tag" ]]; then
        tag_sha="$(gh api "repos/${REPOSITORY}/git/tags/${object_sha}" --jq '.object.sha')" \
            || die "could not peel annotated tag $tag"
    else
        tag_sha="$object_sha"
    fi
    [[ "$tag_sha" == "$HEAD_SHA" ]] \
        || die "$tag points to $tag_sha, but the artifact was built from $HEAD_SHA"
fi

release_exists=false
release_is_draft=false
release_is_immutable=false
if gh_probe "GitHub release $tag" \
    gh release view "$tag" --repo "$REPOSITORY" --json isDraft,isImmutable --jq '[.isDraft, .isImmutable] | @tsv'
then
    release_exists=true
    read -r release_is_draft release_is_immutable <<< "$PROBE_OUT"
fi

if [[ "$release_exists" == "true" && "$release_is_draft" != "true" ]]; then
    die "$tag is already published; use release:repair instead of replacing its asset"
fi
if [[ "$release_is_immutable" == "true" ]]; then
    die "$tag is immutable; refusing to replace its artifact or notes"
fi
if [[ "$preflight" == "true" ]]; then
    printf 'GitHub preflight OK: %s @ %s\n' "$tag" "$HEAD_SHA"
    exit 0
fi

require_command shasum
[[ -f "$ARTIFACT" ]] || die "release artifact is missing: $ARTIFACT"
[[ -f "$MANIFEST" ]] || die "release provenance manifest is missing: $MANIFEST"
[[ -f "$PACKAGE_MANIFEST" ]] || die "Zamok package manifest is missing: $PACKAGE_MANIFEST"
if [[ "$PUBLISH_MODE" != "0" && ! -s "$NOTES_FILE" ]]; then
    die "release notes are missing: $NOTES_FILE"
fi

manifest_value() { sed -n "s/^${1}=//p" "$MANIFEST"; }
manifest_commit="$(manifest_value commit)"
manifest_version="$(manifest_value version)"
manifest_build="$(manifest_value build)"
manifest_channel="$(manifest_value channel)"
manifest_publish="$(manifest_value publish)"
manifest_artifact="$(manifest_value artifact)"
manifest_artifact_sha="$(manifest_value artifact_sha256)"
manifest_notes_sha="$(manifest_value notes_sha256)"

[[ "$manifest_commit" == "$HEAD_SHA" ]] || die "manifest commit does not match HEAD"
[[ "$manifest_version" == "$SHORT_VERSION" ]] || die "manifest version does not match $SHORT_VERSION"
[[ -n "$manifest_build" ]] || die "manifest build is empty"
[[ "$manifest_channel" == "$CHANNEL" ]] || die "manifest channel does not match $CHANNEL"
[[ "$manifest_publish" == "$PUBLISH_MODE" ]] || die "manifest mode does not match PUBLISH=$PUBLISH_MODE"
[[ "$manifest_artifact" == "$(basename "$ARTIFACT")" ]] || die "manifest artifact name does not match"
[[ "$manifest_artifact_sha" == "$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)" ]] \
    || die "artifact SHA-256 does not match the release manifest"
[[ "$manifest_notes_sha" == "$(shasum -a 256 "$NOTES_FILE" | cut -d' ' -f1)" ]] \
    || die "release notes differ from the Markdown sent to Sparkle"

common=(
    --repo "$REPOSITORY"
    --title "$title"
    --notes-file "$NOTES_FILE"
    --draft="$draft"
    --prerelease="$prerelease"
    --latest="$latest"
    --target "$HEAD_SHA"
)

if [[ "$release_exists" == "true" ]]; then
    gh release upload "$tag" "$ARTIFACT" "$PACKAGE_MANIFEST" --repo "$REPOSITORY" --clobber
    gh release edit "$tag" "${common[@]}"
else
    # Always upload into a draft first. Publishing before asset upload races
    # immutable releases and briefly exposes an assetless update.
    gh release create "$tag" "$ARTIFACT" "$PACKAGE_MANIFEST" \
        --repo "$REPOSITORY" \
        --title "$title" \
        --notes-file "$NOTES_FILE" \
        --draft=true \
        --prerelease="$prerelease" \
        --latest=false \
        --target "$HEAD_SHA"
    if [[ "$PUBLISH_MODE" == "1" ]]; then
        gh release edit "$tag" "${common[@]}"
    fi
fi

printf 'GitHub release: https://github.com/%s/releases/tag/%s\n' "$REPOSITORY" "$tag"
