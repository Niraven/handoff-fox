# Contributing to Handoff Fox

Handoff Fox has two halves that fail differently. The Mac app is SwiftUI and AppKit. The Linux side is a Python receiver, a GTK tray, and a few installer scripts. Most changes touch one half, and a few change what both sides agree on: the receiver protocol in [docs/PROTOCOL.md](docs/PROTOCOL.md), pairing, transfers, and jobs. Those need both check suites.

## Repository layout

| Path | What lives there |
| --- | --- |
| `Sources/DesktopLink/` | The Mac menu bar app, quick actions, clipboard, transfer inbox, jobs panel, and the SSH client |
| `peer/desktop_link_peer.py` | The user-level SSH receiver, which speaks the protocol |
| `omarchy/desktop_link.py` | The optional GTK 4 tray and its quick panel |
| `script/` | Build, install, check, and test scripts, plus the optional jobs CLI |
| `dependencies/` | Pinned upstream inputs, their patches, manifests, and license notices |
| `assets/` | The fox sprites, shared by the Mac panel, the tray, and the previews |
| `docs/` | Setup, development, roadmap, protocol, and the support matrix |
| `previews/` | The motion comparison panels and the pilot script |

## Check the halves separately

The Mac half needs macOS with Xcode Command Line Tools and Homebrew. The Linux half needs no Mac at all: Python 3.9 or later and a checkout are enough.

```sh
# Mac: builds the app and compiles the Swift check harnesses
bash script/check_mac.sh

# Linux: receiver, transfer receipts, jobs, and the installers
python3 -B -m unittest discover -s script -p 'test_*.py'
```

Run both when the change alters shared transfer, pairing, or job behaviour. The receiver suite uses temporary state, so it can run anywhere. The Mac suite needs Xcode's Swift toolchain and AppKit, so it cannot be reproduced on Linux.

Also run `bash -n` on each shell script you change and `git diff --check` before you push. GitHub Actions runs the same two commands: `script/check_mac.sh` on `macos-15` and the unittest suite on `ubuntu-24.04`.

## Rules a change must not break

These come from [AGENTS.md](AGENTS.md) and are enforced by review, not by a test:

- **The verified SSH identity stays verified.** Pairing uses the user's `known_hosts`, refuses a changed host key, and keeps the existing receiver if one is present.
- **The protocol stays compatible with pairings that exist.** Receiver changes are additive unless the release notes say a protocol version bump needs a manual receiver update on Linux.
- **A ticket survives a retry.** The ticket is kept across app restarts, and delivery is marked only after the receiver confirms it. No confirmation means no delivery state and no fox celebration.
- **Only owner-approved presets run.** Requests name a project and preset; arguments come from the Linux user's `projects.json`, never from the Mac.
- **Pinned inputs, small patches, real notices.** Update a dependency by changing its manifest and checksums together, and keep the license notices current.
- **No real devices or people in the repo.** Test fixtures use invented names, and screenshots and logs have credentials, addresses, and account names removed.

## Structuring a change

Keep one concern per change and keep the diff readable. Put the logic where a reader would look for it: Mac behaviour in the Swift file that already owns that panel, receiver behaviour in the action that already exists, and installer behaviour in the script that installs it. Match the code around you rather than introducing a new pattern for one function.

Add or extend a check when the behaviour can be observed without a real pair of machines: a receiver unittest or a Swift check harness. Leave note of anything that needs real hardware.

When a change alters what users can do or what has been verified, update the document that makes the claim: [Setup](docs/SETUP.md) for requirements and tested setups, [Development](docs/DEVELOPMENT.md) for build steps and verification, [docs/SUPPORT.md](docs/SUPPORT.md) for the action matrix, and the protocol document for anything on the wire.

## What a reviewer will ask

- Did you run both suites, and which one covers this change?
- What did you exercise on real hardware, and on which Mac and which Linux setup? A cell in the support matrix changes only when the answer names the setup.
- Does the claim match the evidence? Source CI, a live device run, and a signed installer are three different claims.
- Did the protocol, the receiver version, or a saved project format change, and does anything need reinstalling or migrating?
- Are there tests for the failure path, not only the happy one? Interrupted transfers, lost acknowledgments, and dead workers are the cases this project cares about.
- Does the vocabulary match? Transfer tickets, receipts, presets, jobs, and artifacts mean specific things here.

[Report a bug](https://github.com/Niraven/handoff-fox/issues/new?template=bug_report.md) · [Request a feature](https://github.com/Niraven/handoff-fox/issues/new?template=feature_request.md) · [Security policy](SECURITY.md)
