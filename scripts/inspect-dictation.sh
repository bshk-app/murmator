#!/usr/bin/env bash
# Read only metadata: no prompts, transcript text, credentials or response bodies.
set -eu
if (( $# > 1 )); then
    printf '%s\n' 'Usage: scripts/inspect-dictation.sh [15m|1h|1d]' >&2
    exit 2
fi
exec /usr/bin/log show --last "${1:-15m}" --info --style compact --predicate 'process == "Murmator" AND subsystem == "app.bshk.murmur" AND (category == "session-timing" OR category == "cloud-corrector" OR category == "provider-network" OR category == "dictation")'
