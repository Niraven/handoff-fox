# Changelog

All notable changes to Handoff Fox are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project versions releases the way [Semantic Versioning](https://semver.org/) describes, with a preview pre-release tag while the public installer is pending.

## [Unreleased]

### Added

- **A distribution check** (`script/verify_distro.sh`) that runs the receiver over the same JSON interface the Mac uses and prints a report whose rows match the support matrix, with the Mac-side checklist underneath. It ships in the Linux scripts archive.

### Fixed

- **A tagless checkout can build again.** `script/build_and_run.sh` treated the failure of `git describe` as fatal under `set -euo pipefail`, so a shallow clone or a checkout with no tags stopped at the version line instead of falling back to `0.1.0`.
- **A manual release run stamps the tag, not the branch.** Dispatching the release workflow used `github.ref_name`, which is `main` there, so the bundle would have reported `main` as its version.
- **`known_hosts` keeps one key per line.** Trusting a host appended to the file without checking for a trailing newline, which could weld the new key onto the previous line when a tool wrote the file last.
- **The site renderer keeps link titles.** `escape_text` ran before the link and image patterns, so a title in `[x](y "t")` turned into visible Markdown, and quotes in ordinary prose were escaped for no reason.
- **The packaged app reports its release version.** `script/build_and_run.sh` takes `CFBundleShortVersionString` from `HANDOFF_FOX_VERSION` or the nearest tag instead of a hardcoded `0.1.0`, and the release workflow passes the tag through and publishes any tag with a `-` suffix as a GitHub pre-release.

## [0.1.1-preview.2] - 2026-11-25

### Added

- **Transfer Inbox** with a durable ticket per handoff. Items show Queued, Sending, Delivered, or Retry, the destination is named before sending, and a retry after an interrupted send resolves to the same delivery receipt instead of a second copy.
- **Linux-to-Mac handoffs** from the tray. Files and links queue on Linux while the Mac is away, and the Mac receives them into a chosen folder, checks the checksum, and publishes them with an exclusive rename.
- **Linux jobs** with an ID, state, exit code, bounded logs, cancellation, and a SHA-256 verified artifact. Records stay on Linux, so a disconnected Mac can return to the same job. Presets come from the Linux project configuration only.
- **Jobs CLI** (`script/handoff-fox-jobs.py`) for listing projects, starting a preset, reading status, and fetching an artifact over an existing SSH alias.
- **Check connection** with separate results for network reachability, host trust, key sign-in, the receiver, the desktop session, and clipboard tools, each with the recovery step for its own failure.
- **Quick panels** on both platforms, at Control + Option + J on the Mac and Ctrl + Alt + J on Omarchy.
- **Fox companion** states for reconnect and approved jobs, with the same information shown when Reduce Motion is on.
- **CI** on both halves: `script/check_mac.sh` on macOS and the receiver regression suite on Ubuntu.
- **Release workflow** on `v*` tags that runs the Mac checks, packages the app, attaches the archives with their SHA-256 sums, the Linux installers, and build provenance. The packaged app is ad-hoc signed; Developer ID signing and notarization are still pending.
- **Project documents**: [security policy](SECURITY.md), [receiver protocol](docs/PROTOCOL.md), [support matrix](docs/SUPPORT.md), [architecture](docs/ARCHITECTURE.md), [contributing guide](CONTRIBUTING.md), issue and pull request templates, and this changelog.
- **Remote agent sessions**, opt-in and read-only: a receiver action lists tmux panes running a known coding agent, by agent, session and pane name only, never a command line or a path. It reports what is running rather than guessing which session wants attention.
- **A check before pairing**: the first run asks whether the address is reachable, the host key verified, the key accepted and the receiver present, and renders each stage, so an unready machine is a checklist instead of a failed Pair.
- **Trusting a host key without Terminal**: when the key is unknown, pairing shows the key type and its SHA-256 fingerprint so it can be compared with `ssh-keygen -lf` on Linux, and writes `known_hosts` only after the person confirms.
- **Gliff setup guidance**: the desktop card names the exact install command for this distribution, or links the upstream source build when no package is certain to exist. Nothing is installed on the Linux side without the owner.
- **Presets from the Mac**: a saved project can gain a preset whose command must already be an executable inside that project, so the Mac can name work the Linux owner put there but cannot introduce new commands.
- **macOS notifications** for a delivered handoff, a received file, and a job that finishes after the panel closes.

### Changed

- **One design system for every surface.** The palette is sampled from the fox sprites, cards carry a gradient, a lit edge and one shadow, and both appearances work; the forced dark popover is gone. The popover is 264 pt, always states whether the device is reachable, names the send destination on the send row, pairs inline, and pairs nine controls down to four. Motion has one vocabulary, and Reduce Motion keeps the delivery badge.
- **Reachability is tracked per device** and drives the panel, the menu-bar glyph and the accessibility value; an SSH timeout reports as a timeout instead of blaming the network.
- README, Setup, and Development describe the Transfer Inbox, Linux jobs, tray receiving, and the jobs CLI.
- The pinned Gliff viewer patch gained window title and Actual Size options; the upstream release and checksums stay pinned.
- `v0.1.0-preview.1` remains the only tag. The work above ships from source until the next preview tag.

### Fixed

- One unconsumable Linux-to-Mac handoff could hold the delivery queue forever: the receiver gained `reject`, a seven-day outbox TTL, and an atomic publish so a killed `--queue` leaves nothing behind.
- A malformed `projects.json` took the receiver down and answered with a message that named nothing. It now names the file and path, and an interrupted upload that finds another file at its destination re-plans instead of reporting a truncated transfer.
- `job-cancel` was refused while any other action ran; cancel now routes around the busy gate. Job polling is coalesced to one request a second, and the receiver no longer uses `SIGALRM` as a timeout.

### Performance

- One authenticated SSH session per device in both the app and the jobs CLI: a request went from 212 ms to 8 ms against a local sshd, and a tailnet round trip no longer repeats the handshake. Opening the panel prewarms the session.

## [0.1.0-preview.1] - 2026-11-25

### Added

- Mac menu bar app that pairs with a Linux account over the existing OpenSSH key, checking the host key first and installing a user-level receiver when one is missing.
- **Open Desktop** for Hyprland through a checksum-pinned Gliff viewer: Mirror and Private Screen, Fit and Actual Size, and keyboard and pointer sharing with Shift + Escape to release input.
- Manual plain-text clipboard in both directions, with privacy markers refused on both sides.
- File and link handoff from the Mac to Linux, plus a GTK tray for Omarchy that queues files, links, projects, and the desktop for the Mac.
- Saved Linux projects with owner-configured build presets, opened from the menu bar.
- Build and install scripts for both halves: `--verify`, `--install`, and an ad-hoc signed `--package` test ZIP, plus installers for the receiver, the tray, and the Hyprland hotkey.
- Third-party notices and the pinned upstream manifests for the bundled viewer and keymap patches.

[Unreleased]: https://github.com/Niraven/handoff-fox/compare/v0.1.1-preview.2...HEAD
[0.1.1-preview.2]: https://github.com/Niraven/handoff-fox/releases/tag/v0.1.1-preview.2
[0.1.0-preview.1]: https://github.com/Niraven/handoff-fox/releases/tag/v0.1.0-preview.1
