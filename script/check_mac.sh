#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/handoff-fox-checks.XXXXXX")"
trap 'rm -r -- "$check_dir"' EXIT
source=Sources/DesktopLink

swift build
swiftc -parse-as-library "$source"/{FoxDesign,PeerClient,LinuxJobs,Handoff,RemoteDesktop}.swift \
    script/ConnectionChecks.swift -o "$check_dir/connection"
"$check_dir/connection"
swiftc -parse-as-library "$source"/{Handoff,TransferInbox,ClipboardSync,ClipboardTransfer,PeerClient,LinuxJobs}.swift \
    script/TransferInboxChecks.swift -o "$check_dir/transfer"
"$check_dir/transfer"
