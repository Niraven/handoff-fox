# Handoff Fox contributor instructions

## Choose the right surface

- Product direction and scope decisions → [Vision](VISION.md). Roadmap and acceptance criteria → [Roadmap](docs/ROADMAP.md).
- Setup, supported environments, and permissions → [Setup](docs/SETUP.md).
- Builds, runtime checks, and upstream updates → [Development](docs/DEVELOPMENT.md).
- Mac menu bar and Quick Actions → `Sources/DesktopLink/`. Linux tray → `omarchy/desktop_link.py`. SSH receiver and transfer receipts → `peer/desktop_link_peer.py`.
- Mascot and motion → update the shared sprites under `assets/` and inspect [both comparison panels](previews/fox-motion.html). Keep the CLI session row in the mockup while the pilot is pending.

## Preserve the behavior users rely on

- Use the verified SSH host identity and the existing versioned receiver protocol. Keep receiver changes compatible with existing pairings.
- Keep a transfer’s ticket across retries. Mark delivery and trigger the fox reaction only after the receiver confirms it. Keep the destination and retry visible when motion is disabled.
- Run only presets approved in the Linux project’s configuration. Keep agent tooling optional and preserve the permissions of the ordinary desktop, clipboard, and handoff flows.
- For bundled dependencies, use pinned upstream inputs and small patches. Include required notices and keep actual device names, credentials, and user data out of the repository and test artifacts.

## Verify before shipping

1. Run `bash script/check_mac.sh` for Mac changes and `python3 -B -m unittest discover -s script -p 'test_*.py'` for receiver changes. Run both when changing shared transfer, pairing, or job behavior.
2. Run `bash -n` on each changed shell script and `git diff --check` before pushing.
3. Exercise visible changes through the affected native panel or tray. For delivery, send a disposable file, check the received bytes and acknowledgment, then exercise a retry with the same ticket. State which checks ran on real hardware.
4. Match release claims to the evidence. Source CI, live device checks, and a signed and notarized installer each require their own verification.
