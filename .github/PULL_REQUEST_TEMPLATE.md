## What changed

One paragraph. What a user can do now that they could not before, or what failed before that works now.

## Why

The problem or the issue this closes. Link the issue if there is one.

## How it was verified

Tick what you ran and say where.

- [ ] `bash script/check_mac.sh` on macOS (version and Mac model)
- [ ] `python3 -B -m unittest discover -s script -p 'test_*.py'`
- [ ] `bash -n` on each changed shell script
- [ ] `git diff --check`
- [ ] Exercised through the app, tray, or CLI on real hardware (Mac and Linux setup)

If a user-visible change was exercised on a device, name the setup. A support matrix cell in `docs/SUPPORT.md` moves only when the run is recorded in `docs/DEVELOPMENT.md` and the setup is named.

## What is not covered

What you could not test, why, and what a reviewer should try by hand.

## Checklist

- [ ] The change keeps the verified SSH host identity and the existing receiver protocol version, or the notes below say exactly what a pairing must reinstall.
- [ ] A transfer ticket survives a retry, and delivery is marked only after the receiver confirms it.
- [ ] Only presets configured on Linux can be started; no command comes from the Mac.
- [ ] Dependency changes keep their pinned inputs, checksums, and notices current.
- [ ] No real device names, credentials, hostnames, or user data are in the diff, the tests, or the screenshots.
- [ ] The documents that make a claim about this behaviour are updated: Setup, Development, Support, Protocol, or the changelog.

## Notes for the reviewer

Anything that helps a reader start: the risky part, an ordering constraint, or the file to read first.
