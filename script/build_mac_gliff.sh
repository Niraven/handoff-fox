#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/dependencies/mac-gliff.json"
read_manifest() { /usr/bin/plutil -extract "$1" raw "$manifest"; }
version="$(read_manifest release)"
arch="$(uname -m)"
source_hash="$(read_manifest sourceSha256)"
patch="$root/dependencies/$(read_manifest windowPatch)"
patch_hash="$(shasum -a 256 "$patch" | cut -d ' ' -f 1)"
packaging_hash="$(shasum -a 256 "${BASH_SOURCE[0]}" | cut -d ' ' -f 1)"
cache="$root/.build/mac-gliff/$version-$arch-$source_hash-$patch_hash-$packaging_hash"
viewer="$cache/Handoff Fox Desktop.app"
plist="$viewer/Contents/Info.plist"

if [[ -d "$viewer" ]]; then
    # The packager verifies a clean copy. File Provider can attach Finder
    # metadata to app directories stored under a synced workspace.
    printf '%s\n' "$viewer"
    exit 0
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/handoff-gliff-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
archive="$stage/source.tgz"
if [[ $# == 1 ]]; then
    cp "$1" "$archive"
else
    upstream="$(read_manifest upstream)"
    repo="${upstream#https://github.com/}"
    /usr/bin/curl --fail --silent --show-error --location --max-time 60 \
        "https://codeload.github.com/$repo/tar.gz/refs/tags/$version" -o "$archive"
fi
printf '%s  %s\n' "$source_hash" "$archive" | shasum -a 256 -c - >&2
mkdir "$stage/source"
tar -xzf "$archive" --strip-components 1 -C "$stage/source"

(
    cd "$stage/source"
    git apply --check "$patch"
    git apply "$patch"
    # Use upstream's runtime packaging. Keep compiled dependencies between builds.
    mkdir -p "$root/.build/mac-gliff/cargo-$arch"
    ln -s "$root/.build/mac-gliff/cargo-$arch" target
    env -u SIGNING_IDENTITY -u NOTARY_PROFILE bash macos/build-dmg.sh
) >&2

candidate="$stage/Handoff Fox Desktop.app"
mv "$stage/source/dist/Gliff.app" "$candidate"
candidate_plist="$candidate/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string io.github.niraven.handofffox.viewer "$candidate_plist"
/usr/bin/plutil -replace CFBundleName -string 'Handoff Fox Desktop' "$candidate_plist"
/usr/bin/plutil -replace CFBundleDisplayName -string 'Handoff Fox Desktop' "$candidate_plist"
/usr/bin/plutil -insert LSUIElement -bool YES "$candidate_plist"
mkdir "$candidate/Contents/Resources/Notices"
install -m 644 "$stage/source/LICENSE" "$candidate/Contents/Resources/Notices/mac-gliff-LICENSE"
install -m 644 "$stage/source/NOTICE" "$candidate/Contents/Resources/Notices/mac-gliff-NOTICE"
/usr/bin/codesign --force --sign - "$candidate"
/usr/bin/codesign --verify --deep --strict "$candidate"
help="$("$candidate/Contents/MacOS/mac-gliff" --help)"
for option in --window-title --headless --output --no-clipboard --no-audio --actual-size; do
    grep -Fq -- "$option" <<< "$help"
done
mkdir -p "$cache"
/usr/bin/ditto --norsrc --noextattr "$candidate" "$viewer"
/usr/bin/plutil -lint "$plist" >&2
printf '%s\n' "$viewer"
