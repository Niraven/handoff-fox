#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="${1:-}"
manifest="$root/dependencies/waynergy.json"
ref="${2:-$(plutil -extract commit raw "$manifest")}"
patch="$root/dependencies/$(plutil -extract patch raw "$manifest")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/handoff-waynergy-check.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
if [[ -z "$source" ]]; then
    source="$stage/upstream"
    git clone -q --depth 1 --branch "$(plutil -extract release raw "$manifest")" \
        "$(plutil -extract upstream raw "$manifest")" "$source"
fi
mkdir "$stage/snapshot"
git -C "$source" archive "$ref" | tar -xf - -C "$stage/snapshot"
git -C "$stage/snapshot" apply --check "$patch"
printf 'Waynergy Mac keymap patch applies cleanly to %s.\n' "$ref"
