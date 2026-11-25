#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${1:-run}"
case "$mode" in run|--verify|--install|--package|--debug|--logs|--telemetry) ;; *) exit 2 ;; esac
viewer="$(bash "$root/script/build_mac_gliff.sh")"
swift build
binary="$(swift build --show-bin-path)/DesktopLink"
dist="$root/dist"
mkdir -p "$dist"
stage="$(mktemp -d "${TMPDIR:-/tmp}/handoff-fox-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Handoff Fox.app"
published="$dist/Handoff Fox.app"
mkdir -p "$bundle/Contents/MacOS"
if [[ "$mode" != --package ]] && pgrep -x DesktopLink >/dev/null; then
    # Relaunch only this bundle's running copy.
    for pid in $(pgrep -x DesktopLink); do
        command="$(ps -p "$pid" -o command= || true)"
        if [[ "$command" == "$published/Contents/MacOS/DesktopLink"* ]]; then kill -TERM "$pid"; fi
    done
fi
install -m 755 "$binary" "$bundle/Contents/MacOS/DesktopLink"
mkdir -p "$bundle/Contents/Resources"
install -m 644 "$root/LICENSE" "$bundle/Contents/Resources/LICENSE"
install -m 644 "$root/assets/DesktopLink.png" "$bundle/Contents/Resources/DesktopLink.png"
install -m 644 "$root/assets/TrayFox.png" "$bundle/Contents/Resources/TrayFox.png"
install -m 644 "$root/assets/"Fox{Rest,Alert}.png "$bundle/Contents/Resources/"
install -m 644 "$root/peer/desktop_link_peer.py" "$bundle/Contents/Resources/desktop-link-peer"
mkdir -p "$bundle/Contents/Resources/gliff-ssh"
install -m 755 "$root/script/gliff-ssh/ssh" "$bundle/Contents/Resources/gliff-ssh/ssh"
icons="$stage/icons"
mkdir "$icons"
mkdir "$icons/DesktopLink.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/assets/DesktopLink.png" \
        --out "$icons/DesktopLink.iconset/icon_${size}x${size}.png" >/dev/null
    retina="$((size*2))"
    sips -z "$retina" "$retina" "$root/assets/DesktopLink.png" \
        --out "$icons/DesktopLink.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$icons/DesktopLink.iconset" --output "$bundle/Contents/Resources/DesktopLink.icns"
version="${HANDOFF_FOX_VERSION:-$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || true)}"
version="$(printf '%s' "${version:-0.1.0}" | sed 's/^v//')"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DesktopLink</string>
<key>CFBundleIdentifier</key><string>local.desktoplink.control</string>
<key>CFBundleName</key><string>Handoff Fox</string>
<key>CFBundleDisplayName</key><string>Handoff Fox</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>DesktopLink.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
helpers="$bundle/Contents/Helpers"
mkdir -p "$helpers"
/usr/bin/ditto --norsrc --noextattr "$viewer" "$helpers/Handoff Fox Desktop.app"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
if [[ "$mode" == --package ]]; then
    # Archive the signed staging copy before File Provider can attach metadata.
    /usr/bin/ditto -c -k --keepParent --norsrc "$bundle" "$stage/Handoff Fox.zip"
    mv -f "$stage/Handoff Fox.zip" "$dist/Handoff Fox.zip"
    printf '%s\n' "$dist/Handoff Fox.zip"
    exit 0
fi
if [[ -d "$published" ]]; then mv "$published" "$stage/previous.app"; fi
if ! mv "$bundle" "$published"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$published"; fi
    exit 1
fi
bundle="$published"
if [[ "$mode" == --install ]]; then
    installed="$HOME/Applications/Desktop Link.app"
    agent="$HOME/Library/LaunchAgents/local.desktoplink.control.plist"
    domain="gui/$(id -u)"
    mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
    install_stage="$(mktemp -d "$HOME/Applications/.handoff-fox-install.XXXXXX")"
    trap 'rm -rf "$stage" "$install_stage"' EXIT
    /usr/bin/ditto --norsrc --noextattr "$bundle" "$install_stage/Desktop Link.app"
    /usr/bin/codesign --verify --deep --strict "$install_stage/Desktop Link.app"
    for pid in $(pgrep -x DesktopLink || true); do
        command="$(ps -p "$pid" -o command= || true)"
        if [[ "$command" == "$installed/Contents/MacOS/DesktopLink"* ]]; then kill -TERM "$pid"; fi
    done
    if [[ -d "$installed" ]]; then mv "$installed" "$install_stage/previous.app"; fi
    if ! mv "$install_stage/Desktop Link.app" "$installed"; then
        if [[ -d "$install_stage/previous.app" ]]; then mv "$install_stage/previous.app" "$installed"; fi
        exit 1
    fi
    /usr/bin/plutil -create binary1 "$agent"
    /usr/bin/plutil -insert Label -string local.desktoplink.control "$agent"
    /usr/bin/plutil -insert ProgramArguments -array "$agent"
    /usr/bin/plutil -insert ProgramArguments.0 -string /usr/bin/open "$agent"
    /usr/bin/plutil -insert ProgramArguments.1 -string -g "$agent"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$installed" "$agent"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$agent"
    /usr/bin/plutil -lint "$agent"
    if /bin/launchctl print "$domain/local.desktoplink.control" >/dev/null 2>&1; then
        /bin/launchctl bootout "$domain/local.desktoplink.control"
    fi
    /bin/launchctl bootstrap "$domain" "$agent"
    exit 0
fi
/usr/bin/open -n "$bundle"
case "$mode" in
    --verify) sleep 1; pgrep -x DesktopLink ;;
    --debug) lldb -n DesktopLink ;;
    --logs) /usr/bin/log stream --style compact --info --predicate 'process == "DesktopLink"' ;;
    --telemetry) /usr/bin/log stream --style compact --info --predicate 'subsystem == "local.desktoplink.control"' ;;
esac
