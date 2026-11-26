#!/usr/bin/env bash
# Record what a Linux host can prove on its own, before the Mac half of a
# distribution run. The report's rows match docs/SUPPORT.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
peer="${HANDOFF_FOX_PEER:-$root/peer/desktop_link_peer.py}"
report=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --report) report="${2:?--report needs a path}"; shift 2 ;;
        --help|-h)
            printf 'Usage: %s [--report PATH]\n\n' "${BASH_SOURCE[0]}"
            printf 'Runs the checks this Linux host can make alone and prints a Markdown report.\n'
            printf 'The Mac half of the run is listed at the end of the report.\n'
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

rows=()
failures=0

record() {
    rows+=("| $1 | $2 | $3 |")
    if [ "$2" = "fail" ]; then failures=$((failures + 1)); fi
}

clean() {
    printf '%s' "$1" | tr '\n' ' ' | tr '|' '/' | cut -c1-180
}

release_value() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" /etc/os-release 2>/dev/null | head -1
}

field() {
    # field JSON NAME -> first value of "NAME": "text" in the reply
    sed -n "s/.*\"$2\": \"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1
}

count() {
    # count JSON KEY -> how many entries the reply lists under KEY
    python3 -c 'import json, sys
try:
    reply = json.loads(sys.argv[1])
except ValueError:
    print(0)
else:
    value = reply.get(sys.argv[2])
    print(len(value) if isinstance(value, list) else 0)' "$1" "$2" 2>/dev/null || printf '0'
}

distro_id="$(release_value ID)"
distro_name="$(release_value PRETTY_NAME)"
distro_version="$(release_value VERSION_ID)"
distro="${distro_name:-Linux}${distro_id:+ ($distro_id${distro_version:+, $distro_version})}"

compositor="none"
if command -v hyprctl >/dev/null 2>&1; then
    compositor="Hyprland $(hyprctl version 2>/dev/null | sed -n 's/^Hyprland \([^ ]*\).*/\1/p' | head -1)"
fi

session="headless"
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    session="Wayland (${WAYLAND_DISPLAY}, ${XDG_CURRENT_DESKTOP:-desktop unknown})"
elif [ -n "${DISPLAY:-}" ]; then
    session="X11 (${DISPLAY})"
fi

protocol="$(sed -n 's/^VERSION = \(.*\)$/\1/p' "$peer" 2>/dev/null | head -1 || true)"
request() {
    printf '{"version": %s, "action": "%s"}\n' "${protocol:-1}" "$1" \
        | python3 -B "$peer" 2>/dev/null | tail -1 || true
}

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ ! -f "$peer" ]; then
    record "Receiver present" "fail" "$peer is missing"
else
    record "Receiver present" "pass" "protocol ${protocol:-unknown}"
fi

pair_reply="$(request pair)"
if printf '%s' "$pair_reply" | grep -q '"ok": true'; then
    record "Pair: receiver answers" "pass" "$(count "$pair_reply" projects) saved project(s) reported"
else
    record "Pair: receiver answers" "fail" "$(clean "${pair_reply:-no reply}")"
fi

case "$(field "$pair_reply" desktopStatus)" in
    ready) record "Desktop session visible to the receiver" "pass" "ready" ;;
    needsGliff) record "Desktop session visible to the receiver" "fail" "needsGliff: install the Gliff viewer, see the setup hint" ;;
    needsHyprland) record "Desktop session visible to the receiver" "fail" "needsHyprland: no Hyprland socket in this session" ;;
    "") record "Desktop session visible to the receiver" "fail" "no desktopStatus in the pair reply" ;;
    *) record "Desktop session visible to the receiver" "fail" "$(field "$pair_reply" desktopStatus)" ;;
esac

case "$(printf '%s' "$pair_reply" | sed -n 's/.*"clipboardAvailable": \(true\|false\).*/\1/p')" in
    true) record "Clipboard helper reachable" "pass" "wl-clipboard or xclip found in this session" ;;
    false) record "Clipboard helper reachable" "fail" "install wl-clipboard (Wayland) or xclip (X11)" ;;
    *) record "Clipboard helper reachable" "fail" "no clipboardAvailable in the pair reply" ;;
esac

# Reports leave this machine as support evidence, so they carry counts and
# messages rather than host names, project paths, or job output.
for action in job-list agents; do
    reply="$(request "$action")"
    if printf '%s' "$reply" | grep -q '"ok": true'; then
        listed="$([ "$action" = agents ] && printf agents || printf jobs)"
        record "Receiver action: $action" "pass" "$(count "$reply" "$listed") record(s) listed"
    else
        record "Receiver action: $action" "fail" "$(clean "${reply:-no reply}")"
    fi
done

if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import gi; gi.require_version("Gtk", "4.0")' >/dev/null 2>&1; then
        record "Tray prerequisites (PyGObject with Gtk 4)" "pass" "Gtk 4 importable"
    elif python3 -c 'import gi' >/dev/null 2>&1; then
        record "Tray prerequisites (PyGObject with Gtk 4)" "fail" "gi present, Gtk 4 missing"
    else
        record "Tray prerequisites (PyGObject with Gtk 4)" "fail" "install python3-gi and gir1.2-gtk-4.0"
    fi
else
    record "Tray prerequisites (PyGObject with Gtk 4)" "fail" "python3 is missing"
fi

hint="$(request setup-hint)"
if printf '%s' "$hint" | grep -q '"gliffInstalled": true'; then
    record "Gliff viewer installed" "pass" "$(field "$hint" packageManager) package manager"
else
    install="$(field "$hint" command)"
    record "Gliff viewer installed" "fail" "$(clean "${install:-no install command for this distribution; build from source}")"
fi

{
    printf '# Handoff Fox distribution check\n\n'
    printf -- '- Distribution: %s\n' "$distro"
    printf -- '- Session: %s\n' "$session"
    printf -- '- Compositor: %s\n' "$compositor"
    printf -- '- Checked at: %s\n\n' "$started_at"
    printf 'These rows are what this host proves without the Mac. Copy the passing ones into the\n'
    printf '"Another Hyprland distro" column of docs/SUPPORT.md, and cite this report by name in\n'
    printf 'the evidence list with the distribution spelled out.\n\n'
    printf '| Stage | Result | Detail |\n| --- | --- | --- |\n'
    printf '%s\n' "${rows[@]}"
    printf '\n## Still needs the Mac half\n\n'
    cat <<'MAC'
Run these from the Mac against this host; they are the cells this script cannot fill.

- [ ] Pair from a clean Mac: network, host key trust, key sign-in, receiver install
- [ ] Open Desktop, Mirror, and confirm the frame arrives
- [ ] Open Desktop, Private Screen, and type Shift and punctuation
- [ ] Send one disposable file, interrupt it, and retry with the same ticket; the received
      checksum must match
- [ ] Open a saved project folder and a terminal on this host
- [ ] Run one approved job preset, read its exit code and logs, fetch a verified artifact
- [ ] Open the tray card and the quick panel on this host
MAC
} | tee "${report:-/dev/stdout}"

if [ "$failures" -gt 0 ]; then
    printf '\n%d host-side stage(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '\nEvery host-side stage passed.\n'
