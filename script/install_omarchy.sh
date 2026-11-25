#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
application_root="$data_home/applications"
icon_root="$data_home/icons/hicolor/512x512/apps"
autostart_root="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$HOME/.local/bin" "$application_root" "$icon_root" "$autostart_root" "$data_home/desktop-link"
install -m 644 "$root/assets/DesktopLink.png" "$icon_root/local.desktoplink.control.png"
install -m 644 "$root/assets/TrayFox.png" "$data_home/desktop-link/TrayFox.png"
install -m 644 "$root/assets/"Fox{Rest,Alert}.png "$data_home/desktop-link/"
install -m 755 "$root/omarchy/desktop_link.py" "$HOME/.local/bin/desktop-link"
desktop="$application_root/local.desktoplink.control.desktop"
sed "s|^Exec=desktop-link$|Exec=\"$HOME/.local/bin/desktop-link\"|" \
    "$root/omarchy/local.desktoplink.control.desktop" > "$desktop"
chmod 644 "$desktop"
sed '/^Exec=/s/$/ --tray/' "$desktop" > "$autostart_root/local.desktoplink.control.desktop"
chmod 644 "$autostart_root/local.desktoplink.control.desktop"
"$HOME/.local/bin/desktop-link" --status
