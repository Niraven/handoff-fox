# Changelog

All notable changes to Handoff Fox are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project versions releases the way [Semantic Versioning](https://semver.org/) describes, with a preview pre-release tag while the public installer is pending.

## [Unreleased]

### Removed

- **Fields nothing read, and an icon generator nothing called.** `PeerReply` decoded `docs` and `gliffInstalled` on every reply and no view used either; `LinuxJob.createdAt` and three `CitadelActivity` flags were decoded and dropped on the floor; `script/DrawDesktopLinkIcon.swift` was a one-off generator that the asset and `sips` pipeline replaced. The four hand checks that need real hardware stay, now listed in `docs/DEVELOPMENT.md` instead of being invisible files in `script/`.

### Fixed

- **Opening something on Linux is confirmed, not assumed.** A program that hands the work to the session now has 2.5 seconds to say it failed; a non-zero exit raises instead of recording a delivery, and a link whose opener failed leaves no receipt so it can be retried. A program that keeps running is still reported as dispatched.
- **A job artifact belongs to the run that produced it.** The receiver fingerprints the configured artifact before the run — time, size and inode — and when the run left it untouched it collects nothing and records `artifactStale`, so a save button cannot hand over the previous run's bytes.
- **The distribution report carries no host details.** It names the distribution and session, and reports counts and messages rather than the host name, project paths, or job output, because the report is meant to be attached to an issue.
- **The packaged app checks what it bundled.** The build refuses a bundle whose viewer lacks its licence notices or whose icon is missing, in addition to the identifier check.

### Fixed

- **A job no longer keeps running behind a `failed` record.** The monitor records the process group it starts and the kernel's start time for it, and a supervisor that comes back from a dead monitor — or a job recovered after its worker vanished — kills that group and confirms it is gone before the record says `failed`. The start time, not the command text, identifies the process: an earlier version compared `cmdline[0]`, which is the interpreter for any preset with a shebang, so the kill was skipped for every ordinary preset. A recycled PID is left alone.
- **`ack` says what it did, once.** It answers `confirmed`, `dispatched`, or `rejected`, stores that terminal outcome per ticket so a replay returns the same answer, and refuses a ticket it never knew instead of reporting success for a delivery that never happened. A rejected ticket now acks as rejected rather than confirmed.
- **A replay checks the file.** `upload-status` and a repeated upload re-hash the destination and report `verified`, rather than repeating a remembered path after the file was moved or changed.
- **One lock covers the whole outbox.** Sweeping, listing, publishing, acknowledging and rejecting all take the same lock, so an acknowledgement can no longer make the `pending` request fail with a missing manifest. An earlier version took a second lock, which did not serialize anything.
- **`scrape` gives up past its deadline** instead of letting a slow response outlive the 20 seconds the protocol documents.
- **Cancel only applies to the device it was for.** A result arriving after the person switched devices no longer overwrites the new device's panel.
- **The README states the status.** It calls the project an experimental preview, points at the support matrix, and links the release list rather than a stale tag.

### Fixed

- **A saved preset can no longer run a different program than the one it checked.** `save-preset` verified `<project>/name` and stored `name`, which `exec` resolved through `PATH`. It now stores `./name`, so the file that was checked is the file that runs; a bare name from the Linux owner's own configuration keeps its old meaning.
- **An upgrade keeps the viewer and the settings it had.** The viewer cache key now covers how the viewer is packaged rather than only which source it came from, so a warm `.build/mac-gliff` cannot hand the app a viewer with the old identifier, and the build refuses a bundled viewer whose identifier is wrong. The app also copies its preferences out of the previous bundle-identifier domain once, without overwriting anything already set.
- **The preset contract is stated as it is.** `SECURITY.md` promised that arguments are never accepted from a request; `save-preset` does accept them, bounded to an executable already inside the project. The document now describes that, including what it does and does not protect against.
- **Evidence links point at sections.** `docs/SUPPORT.md` cited `DEVELOPMENT.md:64` and similar line numbers that moved as soon as the document grew; they now link to headings.

## [0.1.2-preview.1] - 2026-11-26

### Added

- **An SSH transport test.** The receiver suites call the script directly, so nothing exercised the command the app actually runs over the network. `script/test_ssh_roundtrip.py` starts a local `sshd`, applies the app's own install bootstrap, and checks that the receiver answers on `.local/bin/desktop-link-peer`, that a missing receiver fails with the exit code the app treats as "install it", and that the bootstrap refuses a script whose hash does not match. CI installs `openssh-server`; the install and command cases run there, and a round trip through that sshd runs where it will authenticate and otherwise reports why it skipped.
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
