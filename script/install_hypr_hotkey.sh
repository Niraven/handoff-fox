#!/usr/bin/env bash
set -euo pipefail
hypr="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
test -f "$hypr/bindings.lua"
module="$hypr/handoff-fox.lua"
launcher="$HOME/.local/bin/desktop-link"
printf 'hl.bind("CTRL + ALT + J", hl.dsp.exec_cmd([["%s" --handoff]]))\n' "$launcher" > "$module"
requirement='require("hypr.handoff-fox")'
if ! grep -Fxq "$requirement" "$hypr/bindings.lua"; then
    printf '\n-- Handoff Fox\n%s\n' "$requirement" >> "$hypr/bindings.lua"
fi
if command -v luac >/dev/null; then
    luac -p "$module"
    luac -p "$hypr/bindings.lua"
fi
hyprctl reload
