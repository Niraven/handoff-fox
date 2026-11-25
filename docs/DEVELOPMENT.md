# Development and upstream updates

## Build

- `./script/build_and_run.sh --verify` builds and opens the workspace app.
- `./script/build_and_run.sh --install` installs the app and its user login launcher.
- `./script/build_and_run.sh --package` emits `dist/Handoff Fox.zip` for local testing.
- `./script/install_peer.sh` and `./script/install_omarchy.sh` install the Linux-side receiver and tray when run on Linux.

The Mac menu uses SwiftUI and AppKit. The Linux tray uses GTK 4 and D-Bus. The versioned receiver protocol runs over verified OpenSSH. Building the Mac app packages the Gliff viewer and its runtime inside the app.

GitHub Actions runs `bash script/check_mac.sh` on macOS and the receiver regression suite on Ubuntu. Use those same commands to reproduce a failure locally. The tests use temporary state and the workflow needs read access to the source.

The Mac panel, Omarchy tray card, and [motion previews](../previews/fox-motion.html) share the resting and alert sprites in `assets/`. Keep their 22-pixel grid when updating the artwork. A sender celebrates after a transfer receipt or acknowledgment is recorded. The receiver test suite checks that a queued or missing ticket never reports delivery.

## Update upstream components

The viewer builds from a checksum-pinned mac-gliff source release. `dependencies/mac-gliff-window-title.patch` adds the window title and Actual Size options. Retest both scaling modes and pointer alignment when updating the patch. Video, input, and reconnect come from upstream.

Use `./script/install_mac_gliff.sh --latest` to check for a new release. Review the source, update the source release and checksums in `dependencies/mac-gliff.json`, and package with `./script/build_and_run.sh --package`. The build checks that the patch applies before compiling. Smoke-test Mirror, Private Screen, keyboard and reconnect against the Linux server version before publishing. [mac-gliff releases](https://github.com/teomurgi/mac-gliff/releases) · [Linux Gliff upstream](https://github.com/omacom/gliff)

The optional Waynergy Mac keymap is kept in `dependencies/waynergy-macos-keymap.patch`. Run `./script/check_waynergy_patch.sh` to check the pinned upstream revision. To try a newer revision, pass the path to a Waynergy checkout and the candidate Git ref. Apply the patch in a disposable checkout, run the upstream Meson tests, and verify Mac keyboard input before updating a working link. [Waynergy upstream](https://github.com/r-c-f/waynergy)

## Optional local tools

- The Mac’s pairing panel selects a verified device for incoming handoffs. Existing setups can use `initialLinuxPeer` for the Deskflow and Waynergy input controls and to migrate their previous incoming device.
- The Linux tray reads `HANDOFF_FOX_INPUT_UNIT` to select the relevant user systemd unit. Agent tools depend on the corresponding Linux apps being installed.
- Linux storage listings include home/system storage and a separately mounted `/workspace` when available.

### Build presets

Add a preset to an existing saved project in `~/.config/desktop-link/projects.json`. The receiver honors `XDG_CONFIG_HOME`. Keep the existing ID and path. Only presets configured by the Linux account owner can be started.

```json
{
  "id": "keep-the-existing-id",
  "name": "Example project",
  "path": "/home/you/work/example",
  "presets": [
    {"id": "test", "name": "Test", "argv": ["./ci/test.sh"], "artifact": "build/output.zip"}
  ]
}
```

Old `build` settings appear as a **Build** preset. The optional artifact stays inside the project and can be up to 2 MiB. The Mac and CLI verify its SHA-256 before writing it locally. **Research tools** can also fetch text from a public HTTPS page through the Linux receiver.

```sh
python3 script/handoff-fox-jobs.py user@host projects
python3 script/handoff-fox-jobs.py user@host start PROJECT_ID test
python3 script/handoff-fox-jobs.py user@host status JOB_ID
python3 script/handoff-fox-jobs.py user@host artifact JOB_ID ./result.zip
```

Use the printed job ID with `start PROJECT_ID test --ticket JOB_ID` when an acknowledgment is lost. Jobs run for up to 15 minutes and stay inspectable across SSH disconnects. If the Linux worker disappears, the job is marked failed and the preset is available to run again. Job records and artifacts live under `${XDG_STATE_HOME:-$HOME/.local/state}/desktop-link/jobs`. The app and CLI show the 50 newest records from this directory. Logs are bounded.

For an optional agent integration, register this as a local stdio command with a verified SSH alias and an absolute script path. Each registration covers one device and exposes device info, saved project names and presets, and job metadata. The Mac app and CLI handle job starts, cancellation, logs, and artifacts. [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)

```sh
uv run --with 'mcp>=2,<3' python /absolute/path/to/script/handoff-fox-jobs.py user@host mcp
```

## Preview verification

- On Apple Silicon and Omarchy, the installed Mac app opened both a physical mirror and a separate virtual screen over Tailscale. The private screen accepted keyboard input with Shift and punctuation.
- The viewer opened a private screen in Actual Size and recovered an interrupted SSH connection in the same process. The Omarchy laptop later suspended, resumed, and re-established keyboard and mouse sharing. The Apple Silicon Mac recorded a brief sleep and wake, with the same Mirror viewer present afterward. A sustained Mac sleep and a switch between LAN and Tailscale still need verification.
- An isolated receiver test rejected an unknown host key, installed on a verified login, and preserved the existing receiver on repeat pairing.
- Disposable clipboard and file fixtures passed both clipboard directions and checksum verification for file delivery. The Waynergy patch applied at its pinned revision.
- The Mac shortcut and the Citadel tray opened their quick panels.
- Isolated Citadel jobs returned exit status, logs, and a verified artifact across new SSH sessions. The supervisor-loss regression verifies process cleanup and project unlock. An interrupted acknowledgment test kept one copy of a transferred file across app restart.
- Developer ID and notarization are pending for a public Mac installer.

To prepare the public installer after Developer ID becomes available, inventory licenses in the bundled viewer runtime, sign nested components before the containing app using the same Developer ID team, notarize and staple the app, then verify it with Gatekeeper on a clean Apple Silicon Mac. Time first pairing after preparing the Linux SSH key and confirming its host fingerprint. [Apple notarization steps](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
