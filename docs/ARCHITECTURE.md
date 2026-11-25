# Architecture

How the two halves fit together, which direction each action can travel, and what
a symmetric version costs.

## Roles

The Mac is the controller. Linux runs the agent.

| Side | Component | Speaks |
| --- | --- | --- |
| Mac | `Sources/DesktopLink/` (SwiftUI, `NSStatusItem`, accessory app) | JSON over verified OpenSSH |
| Mac | mac-gliff viewer (pinned, checksum-verified, bundled) | Gliff protocol over the same SSH path |
| Linux | `peer/desktop_link_peer.py` (user-level receiver, `~/.local/bin`) | one JSON request on stdin, one reply on stdout |
| Linux | `omarchy/desktop_link.py` (GTK 4 tray, optional) | receiver CLI plus D-Bus for its own card |
| Linux | Gliff server (upstream, owner-installed) | screen capture and input |

Pairing installs the receiver by hashing it and piping it through the SSH session,
and only when the receiver is missing. Every later request opens a fresh `ssh -T`
with host-key checking on and forwarding off.

## Direction of each action

| Action | Mac → Linux | Linux → Mac | Why the asymmetry |
| --- | --- | --- | --- |
| Open or resume the desktop | Yes | **No** | Only Linux runs a capture server. The bundled viewer is a Gliff *client*; there is nothing on macOS for a Linux client to attach to. |
| Send a file | Yes, 128 MiB, SHA-256, durable ticket | Yes, up to 12 queued while the Mac is away | Linux→Mac is a pull: the tray writes an outbox entry, the Mac polls `pending`, downloads, verifies, then `ack`s. |
| Send a link | Yes, opens on Linux | Yes, opens on the Mac | Same queue as files. |
| Clipboard, manual | Yes | Yes | `clipboard-put` / `clipboard-get` are symmetric requests. |
| Clipboard, automatic | Yes | Yes, when a device is opted in | Needs an active desktop or input pairing. |
| Open a saved project | Yes | No | Projects are a Linux-side concept: a folder path plus approved presets under `~/.config/desktop-link/projects.json`. |
| Run an approved preset | Yes, Linux executes | No | Jobs are deliberately privileged on the side that runs them. |
| Shared keyboard and mouse | Mac input drives Linux | — | Separate from this protocol: Deskflow server on the Mac, Waynergy on Linux, over an SSH local forward to port 24800. |

So the answer to "can it go the other way" is: handoffs already do, the desktop
does not. Linux can push a file, a link, or a clipboard item into the Mac without
any Linux-side viewing capability, because that path needs no listener on the Mac.
Anything that has to *act* on the Mac needs something on the Mac listening.

## Why the Mac is not a receiver

The receiver exists where the work is: it holds the authority of the SSH account it
runs under, so it is installed into that account and audited there. The Mac has no
equivalent — no launchd receiver, no inbound listener, no capture server. The tray's
outbox is a pull model for exactly that reason: the Mac never has to accept a
connection, so it never needs Remote Login enabled.

## Two shapes for symmetry

### A. Mirror the receiver

Port the same protocol to a small macOS receiver installed as a LaunchAgent and
reachable over SSH from Linux.

- Gains: every action becomes symmetric, including files, links, projects and jobs.
- Costs: the Mac must enable Remote Login, which is a security decision most people
  will not make for one utility; a second install surface and a second UI; the Mac
  receiver holds the same authority over the user's account, so it needs the same
  audit the Linux one got.

### B. Make the Mac a peer on the tailnet

The Mac app opens a pairing-scoped listener and the Linux tray talks to it directly
with a token minted at pair time.

- Gains: no Remote Login, no inbound SSH, and pairing already establishes a shared
  secret so the token exchange is cheap.
- Costs: a second transport beside SSH, a firewall prompt on first run, and a
  listener that must be reviewed as carefully as the receiver — a token in the wrong
  hands is remote file write on the Mac.

**Recommendation: B**, and keep the existing pull queue as the "the Mac is away"
fallback. A is only worth it if someone explicitly wants SSH-native symmetry.

Viewing the Mac's desktop from Linux is a third, separate project: it needs a
ScreenCaptureKit server on the Mac and a Wayland viewer on Linux, and it shares no
code with the handoff protocol. Defer it.

## Seams to introduce before either shape

Each of these is small and makes the mirrored direction cheap instead of a fork.

1. **One action type.** `PeerRequest`/`PeerReply` are a flat bag of optionals where
   `project` carries a project id, a transfer ticket *or* a job id, and `text`
   carries clipboard text *or* a SHA-256. A `PeerAction` enum with associated values
   gives one exhaustive dispatch per side and makes a mirrored receiver a switch
   statement instead of a second copy of the parsing.
2. **One SSH invocation value.** The policy is written four times across three
   languages today, and the CLI copy omits `-F`, so a saved alias with a custom
   `ssh_config` works in the app and fails in the CLI.
3. **One device value.** `WorkbenchModel.selected` and `LinkModel.inputPeerAddress`
   are two owners of "which Linux device", and four more per-device facts live in
   separate defaults dictionaries. A single `Device` (address, receives, input bound,
   volume, folder) removes the hand-recombination in every view.
4. **A direction on every transfer.** The ledger already records `incoming` and
   `outgoing`; carrying the same field through the ticket lets one receiver
   implementation serve both ends.
