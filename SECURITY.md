# Security policy

Handoff Fox runs with the authority of the Linux account it is paired with. The Mac asks, and the Linux receiver acts as that user with that user's files, environment, and permissions. There is no separate daemon account, no setuid step, and no privilege escalation: whatever the paired Linux account can do, the receiver can do too. This page states the boundaries that exist today so you can judge the risk before you pair a machine.

## Supported versions

The source preview is the only supported version. That is the `v0.1.0-preview.1` tag and the current `main` branch. Older preview builds are not supported, because the receiver protocol compares its version for equality and a mismatch fails every action. Update the Mac app and re-run `./script/install_peer.sh` on Linux to move both sides together.

A signed and notarized Mac installer does not exist yet. Developer ID signing and notarization are deliberately deferred, so the packaged app is ad-hoc signed and must be built from source to be trusted. See [Setup](docs/SETUP.md) and [Development](docs/DEVELOPMENT.md).

## The trust anchor is the SSH key

Pairing in this preview deliberately does not weaken the SSH settings you already trust. The Mac runs OpenSSH with:

- `StrictHostKeyChecking=yes`, against the host keys in the user's own `known_hosts`. The app never accepts an unknown key for you and never uses `accept-new`. When the key is new, the app stops and asks you to compare the fingerprint in Terminal, as described in [Setup](docs/SETUP.md).
- `BatchMode=yes`. Passwords and interactive prompts are impossible, so the account must already accept a key.
- `ForwardAgent=no`, `ForwardX11=no`, and `ClearAllForwardings=yes`. No agent, X11 session, or TCP forward is created. The only channel is a command channel that runs one program.
- `ConnectTimeout=5`, `ServerAliveInterval=5`, and `ServerAliveCountMax=2`, so a stalled connection ends instead of hanging.

A changed host key is treated as an attack, not a hiccup. The app refuses the connection and tells you the key changed rather than offering to replace it.

These settings narrow the app's own behaviour. They do not sandbox the key. Anyone who holds that SSH key can run anything on the Linux host, receiver or not, so protect the key the way you protect the account. A compromised Mac is a compromised SSH client, and this project cannot make it less than that.

## Installing the receiver

The Mac can push the receiver over the verified connection, but only when the receiver is missing:

- The script is at most 131,072 bytes and its SHA-256 is checked on the Linux side before anything is written.
- It is installed to `~/.local/bin/desktop-link-peer` with mode `0755`, by writing a temporary file in the same directory and linking it into place, so a failed install leaves no partial binary.
- An existing receiver is never replaced. Re-pairing keeps whatever is already there, which is why updates are a manual `./script/install_peer.sh` run from a matching checkout.
- The app does not pin the receiver's digest after installation. It trusts the files in the paired account, so a receiver you edit is a receiver the app will run.

The receiver starts with `umask 077` and creates its state directories with mode `0700`. Its records are readable only by that Linux user.

## What the receiver will and will not run

A request cannot name a program to run. To start work, the Mac names a saved project and a preset ID, and the receiver runs the argument list stored in the Linux user's own configuration at `${XDG_CONFIG_HOME:-~/.config}/desktop-link/projects.json`.

The one way a request adds to that file is `save-preset`, and it is narrower than it sounds: the first argument must name an executable file that already exists inside that project folder, it is stored as a project-relative path so a bare name cannot be resolved through `PATH` to a different program, and it is re-checked when it runs. A saved preset can therefore only run code the Linux account owner placed in the project, but the Mac does choose the arguments passed to it. Any Mac that can reach the receiver already holds the SSH key for that account, so this is a guard against an accident, not a boundary against a stolen key.

Arguments are never stored in job history and never appear in the supervisor's own process arguments. A preset must have an ID of 1 to 64 letters, digits, underscores, or hyphens, a name of at most 64 characters, and a nonempty argument list of NUL-free strings. Projects are capped at 50, must be existing absolute directories, and cannot be added twice. Jobs are capped at 900 seconds and builds at 90 seconds, run in their own process group with an environment reduced to `HOME`, `USER`, `PATH`, `LANG`, `LC_ALL`, `TMPDIR`, and `XDG_CACHE_HOME`, and are killed as a group when they time out or leave a process behind. One job runs per project at a time, enforced with file locks.

Artifacts are read with `O_NOFOLLOW` on every path component, must resolve inside the project folder, are capped at 2 MiB, and are checksummed with SHA-256 at collection and again before they are sent.

`open` starts `xdg-open` on the project folder. `open-terminal` picks the first terminal it finds from a fixed list. `scrape` issues one `GET` to a public HTTPS page. Nothing else leaves the receiver.

## Transfers

- Destinations are fixed: `~/Downloads/Handoff Fox` on the `home` volume, or `/workspace/Handoff Fox/Inbox` when `/workspace` is a mounted, writable volume. A request cannot name another path.
- A volume the receiver does not report is refused, as is a file larger than the space free on the volume.
- Names are validated: at most 220 bytes, no leading dot, no path separators, no control characters, and no `.pem`, `.key`, `.p12`, or `.kdbx` files. A file named `credentials` or `cookies` is refused as well. The check runs on both sides of a transfer.
- Durable transfers write the planned destination to a receipt before publishing, and mark it delivered only after the bytes are in place. A retry with the same ticket verifies the file already there rather than writing a second copy, and a ticket that names a different file is refused.
- Incoming files on the Mac are staged as a hidden partial and published with an exclusive rename, so an existing file or a symlink at the destination is never replaced silently.

## The clipboard gate

Clipboard sharing is plain text only, at most 64 KiB, free of NUL bytes. Both sides check the platform's privacy markers before reading:

- On the Mac, a clipboard item carrying `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, or a password-manager hint is never sent, and manual copies refuse it with a message.
- On Linux, the receiver asks the clipboard for its offered types and refuses items marked concealed, transient, or as a password-manager entry.

Automatic sharing is off by default, enabled per paired device, and needs an active desktop or input pairing. The receiver suppresses echoes of values it just wrote so a copy does not bounce between machines. On X11 only manual copy works; automatic sharing requires Wayland with `wl-clipboard`.

## Scraping public pages

The optional page fetch is the one place the receiver makes its own outbound request, so it is restricted rather than general:

- HTTPS only, on the standard port 443, without embedded credentials.
- Every address the hostname resolves to must be globally routable. Loopback, private, link-local, multicast, and reserved addresses are refused, which blocks requests aimed at the Linux host's own services or the local network.
- The connection goes to the address that was checked, while TLS still verifies the hostname, so a second DNS answer cannot redirect the request.
- Five redirects, a 5-second connection timeout, a 20-second overall limit, a 512,000-byte read, and HTML or plain text only.

The fetch runs on the Linux host, so the remote site sees the Linux connection, not your Mac.

## What stays local

There is no account, no telemetry, no crash reporting, and no server operated by this project. Pairing state lives on the Mac. Receipts, the outbox, job records, logs, and artifacts live in the Linux user's state directory under `${XDG_STATE_HOME:-~/.local/state}/desktop-link`. Both machines talk only to each other, over the SSH connection you configured.

## Reporting a vulnerability

Report privately through GitHub's private advisory flow: [Report a vulnerability](https://github.com/Niraven/handoff-fox/security/advisories/new). Please do not open a public issue for a security problem.

A useful report includes the version or commit, which side is affected, the setup (Mac model and macOS version, Linux distro and compositor, LAN or Tailscale), and the smallest reproduction you have. Remove SSH keys, hostnames, and account names from logs.

What to expect:

- We will confirm the report arrived and tell you what we think, including when we decide something is out of scope.
- We will avoid asking for your SSH private key, your Linux password, or any other credential. If a reproduction needs a specific setup, we will describe it instead.
- We will credit you in the fix unless you ask us not to. There is no bounty program.

Out of scope: bugs in the upstream Gliff viewer, mac-gliff, or Waynergy components, which belong in their own projects and are linked from [Development](docs/DEVELOPMENT.md); anything that requires an attacker to already hold the Linux account or its SSH key; and the warning macOS shows for an ad-hoc signed build, which is the documented state of this preview.

## No warranty

Handoff Fox is released under the [MIT license](LICENSE), without warranty. That license is the whole of the legal agreement. This page explains what the code does today; it is not a claim that the preview is ready for machines you cannot afford to lose.
