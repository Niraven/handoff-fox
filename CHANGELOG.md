# Changelog

All notable changes to Handoff Fox are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project versions releases the way [Semantic Versioning](https://semver.org/) describes, with a preview pre-release tag while the public installer is pending.

## [Unreleased]

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
- **Project documents**: [security policy](SECURITY.md), [receiver protocol](docs/PROTOCOL.md), [support matrix](docs/SUPPORT.md), [contributing guide](CONTRIBUTING.md), issue and pull request templates, and this changelog.

### Changed

- README, Setup, and Development describe the Transfer Inbox, Linux jobs, tray receiving, and the jobs CLI.
- The pinned Gliff viewer patch gained window title and Actual Size options; the upstream release and checksums stay pinned.
- `v0.1.0-preview.1` remains the only tag. The work above ships from source until the next preview tag.

## [0.1.0-preview.1] - 2026-11-25

### Added

- Mac menu bar app that pairs with a Linux account over the existing OpenSSH key, checking the host key first and installing a user-level receiver when one is missing.
- **Open Desktop** for Hyprland through a checksum-pinned Gliff viewer: Mirror and Private Screen, Fit and Actual Size, and keyboard and pointer sharing with Shift + Escape to release input.
- Manual plain-text clipboard in both directions, with privacy markers refused on both sides.
- File and link handoff from the Mac to Linux, plus a GTK tray for Omarchy that queues files, links, projects, and the desktop for the Mac.
- Saved Linux projects with owner-configured build presets, opened from the menu bar.
- Build and install scripts for both halves: `--verify`, `--install`, and an ad-hoc signed `--package` test ZIP, plus installers for the receiver, the tray, and the Hyprland hotkey.
- Third-party notices and the pinned upstream manifests for the bundled viewer and keymap patches.

[Unreleased]: https://github.com/Niraven/handoff-fox/compare/v0.1.0-preview.1...HEAD
[0.1.0-preview.1]: https://github.com/Niraven/handoff-fox/releases/tag/v0.1.0-preview.1
