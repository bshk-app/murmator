#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_command bash
require_command jq
require_command shellcheck
require_command actionlint

note "== parse release scripts =="
for script in "$ROOT"/scripts/*.sh; do
    bash -n "$script"
    # lib.sh is sourced, never executed: it is the one file without +x.
    [[ "$script" == */lib.sh || -x "$script" ]] \
        || die "script is not executable: ${script#"$ROOT"/}"
done
shellcheck -x "$ROOT"/scripts/*.sh
[[ -x "$ROOT/scripts/sparkle-public-key.swift" ]] \
    || die "scripts/sparkle-public-key.swift is not executable"

if [[ "$(uname -s)" == "Darwin" ]]; then
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT
    SPARKLE_PRIVATE_ED_KEY='nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=' \
    SPARKLE_PUBLIC_ED_KEY='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=' \
        "$ROOT/scripts/export-sparkle-key.sh" "$key_file"
    derived="$("$ROOT/scripts/sparkle-public-key.swift" "$key_file")"
    [[ "$derived" == '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=' ]] \
        || die "Sparkle Ed25519 derivation failed its RFC 8032 test vector"
    rm -f "$key_file"
    trap - EXIT
fi

note "== validate workflows =="
actionlint "$ROOT"/.github/workflows/*.yml

note "== validate release JSON =="
jq -e . "$ROOT/release-please-config.json" >/dev/null
jq -e . "$ROOT/.release-please-manifest.json" >/dev/null
jq -e . "$ROOT/Distribution/cask-murmur.json" >/dev/null
jq -e '.pins | length > 0' "$ROOT/.package.resolved" >/dev/null

version="$(read_version)"
manifest_version="$(jq -r '.["."]' "$ROOT/.release-please-manifest.json")"
[[ "$manifest_version" == "$version" ]] \
    || die ".release-please-manifest.json ($manifest_version) does not match VERSION ($version)"
[[ "$(jq -r '.packages["."]."package-name"' "$ROOT/release-please-config.json")" == "murmur" ]] \
    || die "release-please package-name must be murmur"
[[ "$(jq -r '."include-component-in-tag"' "$ROOT/release-please-config.json")" == "true" ]] \
    || die "release-please must emit murmur-vX.Y.Z tags"
[[ "$(jq -r '.draft' "$ROOT/release-please-config.json")" == "true" ]] \
    || die "release-please must create a draft before assets are uploaded"
[[ "$(jq -r '.["force-tag-creation"]' "$ROOT/release-please-config.json")" == "true" ]] \
    || die "draft releases need force-tag-creation before the build can checkout the tag"

build_number="$("$ROOT/scripts/build-number.sh")"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "build number is not an integer"
[[ -s "$ROOT/BUILD_NUMBER_BASE" ]] || die "BUILD_NUMBER_BASE is empty"

notes="$("${ROOT}/scripts/extract-release-notes.sh" "$version" "$ROOT/CHANGELOG.md")"
[[ -n "$notes" ]] || die "CHANGELOG has no section for VERSION $version"

feed="$(jq -r '.livecheckUrl' "$ROOT/Distribution/cask-murmur.json")"
strategy="$(jq -r '.livecheckStrategy' "$ROOT/Distribution/cask-murmur.json")"
[[ "$feed" == "https://raw.githubusercontent.com/bshk-app/murmur/main/appcast.xml" ]] \
    || die "cask must follow the legacy-compatible appcast"
[[ "$strategy" == "sparkle" ]] || die "cask livecheckStrategy must be sparkle"
grep -Fq 'https://raw.githubusercontent.com/bshk-app/murmur/main/appcast.xml' "$ROOT/Project.swift" \
    || die "Murmur.app and the cask must read the same appcast"
[[ "$(release_tag "$version" stable)" == "murmur-v${version}" ]] \
    || die "release_tag must emit murmur-vX.Y.Z on the stable channel"
[[ "$(release_tag "$version" beta)" == "murmur-v${version}-beta" ]] \
    || die "release_tag must suffix every non-stable channel"

# The monotonic build guard is the one check whose failure is unrecallable, so
# exercise its parser here rather than trusting it on release night.
published_fixture='<item><sparkle:version>0.1.1</sparkle:version></item>
<item><sparkle:version>1013</sparkle:version></item>
<item><sparkle:version>1121</sparkle:version></item>'
[[ "$(printf '%s\n' "$published_fixture" | newest_published_build)" == "1121" ]] \
    || die "newest_published_build must return the highest integer build"
string_fixture='<item><sparkle:version>0.1.1</sparkle:version></item>'
[[ -z "$(printf '%s\n' "$string_fixture" | newest_published_build)" ]] \
    || die "newest_published_build must ignore non-integer versions"
grep -q 'assert_build_number_increases' "$ROOT/scripts/release.sh" \
    || die "stable release must refuse a build number the feed already passed"
workflow="$ROOT/.github/workflows/release.yml"
grep -q 'source ./scripts/lib.sh' "$workflow" \
    || die "release workflow must source scripts/lib.sh for the shared rules"
grep -q 'expected=.*release_tag' "$workflow" \
    || die "release workflow must derive the expected tag from release_tag"
is_github_repository_url 'https://github.com/bshk-app/murmur' 'bshk-app/murmur' \
    || die "GitHub HTTPS remotes without .git must be accepted"
is_github_repository_url 'git@github.com:bshk-app/murmur.git' 'bshk-app/murmur' \
    || die "GitHub SSH remotes with .git must be accepted"
if is_github_repository_url 'ssh://git@truenas.local/beshkenadze/murmur.git' 'bshk-app/murmur'; then
    die "the private Gitea origin must never receive the public Sparkle feed"
fi
if is_github_repository_url 'https://evilgithub.com/bshk-app/murmur.git' 'bshk-app/murmur'; then
    die "lookalike hosts must not receive the public Sparkle feed"
fi

# A signed, notarized artifact must not be built from whatever a branch happened
# to point at, and a branch dependency also rewrites Package.resolved on every
# fresh resolve - which used to fail the release after notarization.
if grep -q 'branch:' "$ROOT/MurmurKit/Package.swift"; then
    die "MurmurKit must pin dependencies by revision or version, never by branch"
fi
grep -q 'require_clean_pushed_tree' "$ROOT/scripts/release.sh" \
    || die "release.sh must gate tree cleanliness before it builds anything"
if grep -q 'require_clean_pushed_tree' "$ROOT/scripts/publish-github-release.sh"; then
    die "publishing runs after the build; it must not re-check the working tree"
fi
grep -q 'get-url --push' "$ROOT/scripts/publish-appcast.sh" \
    || die "appcast publishing must validate the GitHub push URL, not only fetch"
grep -q 'stable appcast requires tag' "$ROOT/scripts/publish-appcast.sh" \
    || die "direct appcast publishing must reject beta tags"
grep -q 'verify_github_release_asset' "$ROOT/scripts/publish-appcast.sh" \
    || die "appcast must sign the exact immutable GitHub asset"
grep -q 'stable cask requires tag' "$ROOT/scripts/publish-cask.sh" \
    || die "direct cask publishing must reject beta tags"
grep -q 'verify_github_repo_write.*TAP_GITHUB_TOKEN' "$ROOT/scripts/release.sh" \
    || die "stable release must verify tap write scope before build/publication"
forbidden_token_env="GITHUB_TOKEN=\"\$token\" gh api"
required_token_env="GH_TOKEN=\"\$token\" gh api"
if grep -q "$forbidden_token_env" "$ROOT/scripts/lib.sh"; then
    die "GH_TOKEN has precedence; tap write probe must authenticate with GH_TOKEN"
fi
grep -q "$required_token_env" "$ROOT/scripts/lib.sh" \
    || die "tap write probe is not using the supplied token"
grep -q 'TAP_WRITE_VERIFIED_REPOSITORY' "$ROOT/scripts/publish-cask.sh" \
    || die "release must not run the public tap write probe twice"
grep -q 'TAG.*==.*expected' "$workflow" \
    || die "release workflow must reject a tag that disagrees with VERSION"
grep -q '^  workflow_dispatch:' "$workflow" \
    || die "release workflow needs workflow_dispatch as its recovery path"
if grep -q 'types: \[published\]' "$workflow"; then
    die "release:published would recurse when task release uses maintainer credentials"
fi
if grep -q 'gh release edit' "$workflow"; then
    die "workflow must not mutate release notes before scripts/release.sh preflight"
fi
awk '
    /^  release-scripts:/ { in_job = 1 }
    in_job && /fetch-depth: 0/ { found = 1 }
    END { exit(found ? 0 : 1) }
' "$ROOT/.github/workflows/ci.yml" \
    || die "release-scripts CI needs full history for the build number"

if command -v plutil >/dev/null 2>&1; then plutil -lint "$ROOT/Murmur.entitlements" >/dev/null; fi
if command -v zamokctl >/dev/null 2>&1; then require_zamokctl; fi

printf 'Release configuration OK: Murmur %s (build %s)\n' "$version" "$build_number"
