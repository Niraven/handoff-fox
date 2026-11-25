# Support matrix

What has actually been run, per action and per setup. Three states, no others:

- **verified** means someone exercised it on that setup and wrote it down. Every verified cell carries the line it comes from.
- **untested** means the code path exists but no run is recorded for that setup. It may work. Nobody has shown that it does.
- **unsupported by design** means the preview does not attempt it on that setup, and a request that needs it fails with a message instead of half-working.

A cell becomes verified only when a run is recorded and the setup is named. "It should work" does not move a cell.

## Actions

| Action | Omarchy with Hyprland and Gliff | Another Hyprland distro | Headless SSH host | Mac side |
| --- | --- | --- | --- | --- |
| Pair: network, host trust, key sign-in, receiver install | verified [3][7] | untested | verified [8] | verified [3][7] |
| Open Desktop, Mirror | verified [1][7] | untested [9] | unsupported by design | verified [1] |
| Open Desktop, Private Screen | verified [1][7] | untested [9] | unsupported by design | verified [1] |
| Actual Size | verified [2] | untested | unsupported by design | verified [2] |
| Keyboard and pointer input | verified [1][2] | untested [9] | unsupported by design | verified [1] |
| Reconnect after an interrupted SSH connection | verified [2][7] | untested | untested | verified [2] |
| Manual clipboard, both directions | verified [4]† | untested [9] | unsupported by design | verified [4]† |
| Automatic clipboard, per device | untested | untested | unsupported by design | untested |
| Send a file from the Mac | verified [4]† | untested | untested | verified [4]† |
| Receive a file queued on Linux | verified [6] | untested | untested | verified [6] |
| Retry an interrupted transfer with the same ticket | verified [6]† | untested | untested | verified [6]† |
| Send a link | untested | untested | untested | untested |
| Open a saved project folder or terminal | untested | untested | untested | untested |
| Read a job's status, logs, and exit code | verified [6] | untested | untested | verified [6] |
| List saved projects and jobs | untested | untested | verified [8] | untested |
| Run an approved job preset | verified [6] | untested | untested | verified [6] |
| Cancel a running job | untested | untested | untested | untested |
| Fetch a verified job artifact | verified [6] | untested | untested | verified [6] |
| Fetch a public page for research tools | untested | untested | untested | untested |
| Tray card and quick panel | verified [5][7] | untested | unsupported by design | verified [5] |
| List running agent sessions | untested | untested | untested | untested |

### Why the empty rows are empty

The headless column has no desktop, so desktop, input, clipboards, and the tray are out of scope there by design. Transfer, project, and job actions are not, and the headless setup has a verified install and a verified job listing, nothing more. A headless host can still receive files and run approved presets; nobody has recorded doing it.

Automatic clipboard has code on both sides but no recorded run on any setup, and it needs a Wayland session with `wl-clipboard` [9]. Manual copy is the verified path.

Links, saved-project shortcuts, job cancellation, and the research fetch are implemented and documented in [Setup](SETUP.md) and [Development](DEVELOPMENT.md). None of them has a record of being exercised on a device, so all of their cells stay untested until one does.

## Evidence

- [1] [DEVELOPMENT.md:64](DEVELOPMENT.md) — On Apple Silicon and Omarchy, the installed app opened a physical mirror and a separate virtual screen over Tailscale. The private screen accepted keyboard input with Shift and punctuation.
- [2] [DEVELOPMENT.md:65](DEVELOPMENT.md) — The viewer opened a private screen in Actual Size and recovered an interrupted SSH connection in the same process. The Omarchy laptop suspended, resumed, and re-established keyboard and mouse sharing. A brief Mac sleep and wake kept the Mirror viewer.
- [3] [DEVELOPMENT.md:66](DEVELOPMENT.md) — An isolated receiver test rejected an unknown host key, installed on a verified login, and preserved the existing receiver on repeat pairing.
- [4] [DEVELOPMENT.md:67](DEVELOPMENT.md) — Disposable clipboard and file fixtures passed both clipboard directions and checksum verification for file delivery.
- [5] [DEVELOPMENT.md:68](DEVELOPMENT.md) — The Mac shortcut and the Citadel tray opened their quick panels.
- [6] [DEVELOPMENT.md:69](DEVELOPMENT.md) — Isolated jobs returned exit status, logs, and a verified artifact across new SSH sessions. The supervisor-loss regression verifies cleanup and project unlock. An interrupted acknowledgment test kept one copy of a transferred file across an app restart.
- [7] [SETUP.md:46](SETUP.md) — Omarchy with Hyprland and Gliff: pairing, Mirror and Private Screen over Tailscale, reconnect after interrupting SSH, and the GTK tray.
- [8] [SETUP.md:47](SETUP.md) — Debian 13 without a desktop: fresh SSH receiver installation and job listing.
- [9] [SETUP.md:49](SETUP.md) — Keyboard and clipboard support depend on the desktop session and input pairing. First-time onboarding on a clean Mac and desktop control on a second Hyprland distro remain to be verified.
- [10] [DEVELOPMENT.md:70](DEVELOPMENT.md) — Developer ID and notarization are pending for a public Mac installer.

† [4] records that the clipboard and file fixtures passed without naming the Linux setup they ran on, so this row cites the run rather than a distro. † under [6] is the Linux-to-Mac direction: the interrupted acknowledgment was a file queued on Linux and received on the Mac. The Mac-to-Linux retry is covered by `script/test_transfer_receipts.py` in the receiver suite, which is a regression test and not a hardware record.

## Not in this preview

- A Developer ID signed, notarized Mac installer. The packaged app is ad-hoc signed, and building from source is the verified path [10]. See [SETUP.md:21](SETUP.md).
- The Mac target is macOS 14 or later on Apple Silicon. The preview was built and run on one Apple Silicon Mac [SETUP.md:5](SETUP.md).

[Protocol reference](PROTOCOL.md) · [Security policy](../SECURITY.md) · [Share feedback about your setup](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md)
