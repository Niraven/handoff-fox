#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
install -d "$HOME/.local/bin"
install -m 755 "$root/peer/desktop_link_peer.py" "$HOME/.local/bin/desktop-link-peer"
printf '%s\n' 'Desktop Link receiver installed for this Linux user.'
