# Development and upstream updates

## Build

- `./script/build_and_run.sh --verify` builds and opens the workspace app.
- `./script/build_and_run.sh --install` installs the app and its user login launcher.
- `./script/build_and_run.sh --package` emits `dist/Handoff Fox.zip` for local testing.
- `./script/install_peer.sh` and `./script/install_omarchy.sh` install the Linux-side receiver and tray when run on Linux.

The Mac menu uses SwiftUI and AppKit. The Linux tray uses GTK 4 and D-Bus. The versioned receiver protocol runs over verified OpenSSH. Building the Mac app packages the Gliff viewer and its runtime inside the app.

## Update upstream components

The viewer builds from a checksum-pinned mac-gliff source release. `dependencies/mac-gliff-window-title.patch` adds the window title switch. Video, input, and reconnect come from upstream.

Use `./script/install_mac_gliff.sh --latest` to check for a new release. Review the source, update the source release and checksums in `dependencies/mac-gliff.json`, and package with `./script/build_and_run.sh --package`. The build checks that the patch applies before compiling. Smoke-test Mirror, Private Screen, keyboard and reconnect against the Linux server version before publishing. [mac-gliff releases](https://github.com/teomurgi/mac-gliff/releases) · [Linux Gliff upstream](https://github.com/omacom/gliff)

The optional Waynergy Mac keymap is kept in `dependencies/waynergy-macos-keymap.patch`. Run `./script/check_waynergy_patch.sh` to check the pinned upstream revision. To try a newer revision, pass the path to a Waynergy checkout and the candidate Git ref. Apply the patch in a disposable checkout, run the upstream Meson tests, and verify Mac keyboard input before updating a working link. [Waynergy upstream](https://github.com/r-c-f/waynergy)

## Optional local tools

- The Mac’s `initialLinuxPeer` preference selects a verified device for incoming handoffs, automatic clipboard, and optional input controls. The input controls use existing Deskflow and Waynergy services.
- The Linux tray reads `HANDOFF_FOX_INPUT_UNIT` to select the relevant user systemd unit. Agent tools depend on the corresponding Linux apps being installed.
- Linux storage listings include home/system storage and a separately mounted `/workspace` when available.

### Build presets

Add a preset to an existing saved project in `~/.config/desktop-link/projects.json`. The receiver honors `XDG_CONFIG_HOME`. Keep the existing ID and path.

```json
{
  "id": "keep-the-existing-id",
  "name": "Example project",
  "path": "/home/you/work/example",
  "build": ["./ci/build.sh"],
  "artifact": "build/output.zip"
}
```

The optional artifact stays inside the project and can be up to 2 MiB. The Mac verifies its SHA-256. **Research tools** can also fetch text from a public HTTPS page through the Linux receiver.

## Preview verification

- On Apple Silicon and Omarchy, the installed Mac app opened both a physical mirror and a separate virtual screen over Tailscale. The private screen accepted keyboard input with Shift and punctuation.
- An isolated SSH interruption recovered in the same Mac viewer window while both laptops stayed awake. Physical sleep and wake remain untested.
- An isolated receiver test rejected an unknown host key, installed on a verified login, and preserved the existing receiver on repeat pairing.
- Disposable clipboard and file fixtures passed both clipboard directions and checksum verification for file delivery. The Waynergy patch applied at its pinned revision.
- Developer ID and notarization are pending for a public Mac installer.
