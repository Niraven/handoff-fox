#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/dependencies/mac-gliff.json"
mode="${1:---check}"
installed="$HOME/Applications/Handoff Fox Gliff.app"
read_manifest() { /usr/bin/plutil -extract "$1" raw "$manifest"; }

verify() {
    local app="$1"
    /usr/bin/codesign --verify --deep --strict "$app"
    /usr/sbin/spctl --assess --type execute "$app"
    /usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/grep -Fx "TeamIdentifier=$(read_manifest teamId)" >/dev/null
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" = "$(read_manifest bundleId)"
}
expected="$(read_manifest release)"
if [[ "$mode" == --check ]]; then
    verify "$installed"
    installed_version="$("$installed/Contents/MacOS/mac-gliff" --version)"
    printf 'Installed %s. Recorded release %s.\n' "$installed_version" "$expected"
    test "$installed_version" = "mac-gliff ${expected#v}" || test "$installed_version" = "mac-gliff.bin ${expected#v}"
    exit
fi
if [[ "$mode" == --latest ]]; then
    /usr/bin/curl --fail --silent --show-error --location --max-time 20 \
        https://api.github.com/repos/teomurgi/mac-gliff/releases/latest |
        /usr/bin/plutil -extract tag_name raw -o - -
    exit
fi
[[ "$mode" == --install ]]
[[ "$(uname -m)" == "$(read_manifest arch)" ]] || { printf '%s\n' 'No verified Gliff installer is recorded for this Mac architecture.' >&2; exit 1; }
stage="$(mktemp -d "${TMPDIR:-/tmp}/handoff-gliff-install.XXXXXX")"
mount="$stage/mount"
mkdir "$mount"
cleanup() {
    if test -d "$mount/Gliff.app"; then hdiutil detach "$mount" >/dev/null 2>&1 || true; fi
    rm -rf "$stage"
}
trap cleanup EXIT
asset="$(read_manifest asset)"
dmg="$stage/$asset"
if [[ $# == 2 ]]; then
    cp "$2" "$dmg"
else
    /usr/bin/curl --fail --silent --show-error --location --retry 2 --max-time 90 \
        "$(read_manifest upstream)/releases/download/$expected/$asset" -o "$dmg"
fi
printf '%s  %s\n' "$(read_manifest sha256)" "$dmg" | /usr/bin/shasum -a 256 -c -
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" >/dev/null
verify "$mount/Gliff.app"
help="$("$mount/Gliff.app/Contents/MacOS/mac-gliff" --help)"
for option in --headless --output --no-clipboard --no-audio; do
    grep -Fq -- "$option" <<< "$help"
done
mkdir -p "$HOME/Applications"
candidate="$HOME/Applications/.handoff-fox-gliff-candidate.$$.app"
/usr/bin/ditto "$mount/Gliff.app" "$candidate"
verify "$candidate"
if [[ -d "$installed" ]]; then
    verify "$installed"
    backup="$HOME/Library/Application Support/Handoff Fox/Previous Gliff"
    mkdir -p "$backup"
    previous="$backup/Gliff-$(date +%Y%m%d-%H%M%S).app"
    mv "$installed" "$previous"
    if ! mv "$candidate" "$installed"; then
        mv "$previous" "$installed"
        exit 1
    fi
else
    mv "$candidate" "$installed"
fi
printf 'Installed and verified signed mac-gliff %s.\n' "$expected"
