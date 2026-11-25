# Receiver protocol

The Mac app talks to a Linux account by running `~/.local/bin/desktop-link-peer` over the OpenSSH connection the user already has. There is no listening port and no daemon. Each request is one SSH command, one JSON document on stdin, and one JSON document on stdout. Anything that can run a command over SSH with that user's key can speak this protocol.

The receiver is [peer/desktop_link_peer.py](../peer/desktop_link_peer.py). The Mac client is [PeerClient.swift](../Sources/DesktopLink/PeerClient.swift). This document describes the protocol as shipped in `v0.1.0-preview.1` and `main` today, protocol version 1.

## Transport

The client runs:

```sh
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o ForwardAgent=no \
    -o ForwardX11=no -o ClearAllForwardings=yes -- user@host .local/bin/desktop-link-peer
```

The command runs in the Linux user's login environment. OpenSSH normally provides no `DISPLAY` or `WAYLAND_DISPLAY` there, so the receiver reads the session variables from `systemctl --user show-environment` or launches through `systemd-run --user` when it needs a graphical session.

Requests are UTF-8 JSON objects on stdin and are read in full before dispatch. The receiver accepts up to 420,000 bytes; the Mac client caps non-clipboard requests at 16,384 bytes.

Replies are one JSON object printed on stdout with a trailing newline. Because SSH diagnostics share the connection, a client should take the last non-empty line of output rather than parse the whole stream. The Mac client aborts a reply longer than 3,500,000 bytes.

The receiver writes a reply and exits 0 even when the action fails. Nonzero exit status means the SSH layer or the interpreter failed, not the action:

| Status | Meaning |
| --- | --- |
| `0` | A JSON reply was printed. Check its `ok` field. |
| `126` | The receiver exists but could not be executed. |
| `127` | The receiver is missing, or `python3` is not installed. |
| `83` | The installer refused to install because Python is older than 3.9. |
| `85` | A receiver the client pushed over the connection failed its SHA-256 check. |
| `255` | SSH could not connect, the host key did not verify, or authentication failed. |

A client that wants the four distinct setup failures should read SSH's stderr, as the Mac app does: `HOST IDENTIFICATION HAS CHANGED`, `Host key verification failed`, `Permission denied`, and a missing receiver each get their own message and their own recovery step. Everything else is a network or reachability problem.

Client timeouts are 12 seconds for `pair` and `desktop`, 110 seconds for `build`, and 32 seconds for every other action. `pending` returns on its own within 18 seconds.

## Envelope

Every request carries `version` and `action`:

```json
{"version": 1, "action": "pair"}
```

Every reply carries `version`, `ok`, and, when `ok` is false, `error`:

```json
{"version": 1, "ok": false, "error": "This project is no longer saved on Linux."}
```

The request fields are `version`, `action`, `project`, `name`, `path`, `url`, `text`, `job`, and `preset`. Not every action uses every field, and a few actions reuse `project` to carry a transfer ticket rather than a project ID; the action table below says which. The current schema is shallow on purpose: it is one flat object per request, and the Mac client encodes it from a single Swift struct.

`error` strings are written for the person using the app. They say what to fix on Linux or on the network. A client should show them as they are rather than rewriting them.

## Actions

### `pair`

Reports what the Linux side can do. This is the action behind pairing and **Check connection**, and it is safe to call at any time.

Returns `name` (hostname), `system` (`Linux`), `projects`, `volumes`, `desktopStatus`, `clipboardAvailable`, `jobProtocol`, and `transferProtocol`.

```json
{
  "version": 1, "ok": true,
  "name": "workstation", "system": "Linux",
  "projects": [{"id": "3f0c…", "name": "Example", "canBuild": true,
                "presets": [{"id": "test", "name": "Test"}]}],
  "volumes": [{"id": "home", "name": "System & home", "path": "/home/you",
               "free": 412341, "total": 900000}],
  "desktopStatus": "ready",
  "clipboardAvailable": true,
  "jobProtocol": 1, "transferProtocol": 1
}
```

`volumes` lists `home` always and `workspace` only when `/workspace` is a mount point the user can write to. `free` and `total` are bytes.

### `desktop`

Prepares the viewer for **Open Desktop**. Takes no fields. Returns `title` (the `gliff-server --version` string) and, when `gliff-probe` is installed and reports outputs, `desktopOutput` with the name of the first output that is not Gliff's own virtual display. Fails with a specific message when Hyprland is not running or Gliff is not installed. The Mac uses `desktopOutput` to pick which Linux display to stream.

### `open-link`

Field: `url`. Opens an HTTP or HTTPS link with `xdg-open` in the Linux session. Returns `{}`.

### `deliver-link`

Fields: `url`, `project` (a transfer ticket). Records a receipt and opens the link once for that ticket. Returns `{}`. A second call with the same ticket and the same URL returns `{}` without opening anything again; a different URL under the same ticket is an error. If the earlier attempt may have opened and no delivery was recorded, the receiver refuses and asks for a new ticket.

### `reveal-upload`

Field: `project` (a ticket). Opens the folder that received the file, so the person can see it on Linux. Returns `{}`. Requires a delivered `--upload-ticket` receipt.

### `upload-status`

Fields: `project` (a ticket) and `text` (the file's SHA-256 as hex). Tells a retry whether the ticket already landed. Returns `path` and `sha256` when it did, `{}` when that ticket has no delivered receipt. A digest that does not match the ticket's manifest is an error. This is how the Mac avoids sending the same bytes twice after a lost reply.

### `pending`

Long-polls for items the Linux tray queued for the Mac. Takes no fields. Returns `handoffs`, the outbox contents in queue order, and waits up to 18 seconds before returning an empty list. Each item is `{"id", "kind"}` plus `name`, `size`, `sha256` for `file`, or `url` for `link`. `kind` is `file`, `link`, `projects`, or `desktop`. The Mac fetches a file with `--download` and then calls `ack`.

### `ack`

Field: `project` (a ticket). Removes the outbox item and its payload. For a file it first writes a delivery receipt, so the Linux tray can show the file as delivered. Returns `{}`.

### `mac-file-status`

Field: `project` (a ticket). Returns `transferStatus` as `queued`, `delivered`, or `unknown`, so the Linux tray can show where its file went.

### `save`

Fields: `name` and `path`. Adds a project to `projects.json` and returns the whole `projects` list in the `pair` shape. The name is at most 64 characters, the path must be an existing absolute directory, duplicates are refused, and the file holds at most 50 projects. The write is serialized with `flock` and published with `os.replace`, so a reader never sees a partial file.

### `clipboard-put` and `clipboard-get`

`clipboard-put` takes `text` and writes it to the Linux desktop clipboard. `clipboard-get` takes nothing and returns `text`. Text is UTF-8, nonempty, free of NUL bytes, and at most 64 KiB. Writing needs `wl-copy` in a Wayland session or `xclip` on X11. Reading first asks the clipboard for its offered types and refuses when Linux marked the item concealed, transient, or as a password-manager entry.

### `scrape`

Field: `url`. Fetches a public HTTPS page and returns `title`, `output`, `exitCode` (always 0), `truncated`, and `elapsedMs`. Text is extracted from HTML and trimmed to 48,000 bytes. The URL must be HTTPS on port 443, must not carry credentials, and every address its hostname resolves to must be globally routable; the connection goes to the address that was checked while TLS still verifies the hostname. Five redirects, a 5-second connect timeout, a 20-second overall alarm, a 512,000-byte page read, and `text/html`, `text/plain`, or `application/xhtml+xml` only. This is the receiver behind an optional research tool, and it is the only action that makes an outbound network request of its own.

### `open`, `open-terminal`, `build`

Field: `project`, a project ID from `pair`. `open` opens the project folder, `open-terminal` opens a terminal in it, and both return `title`. `build` runs the project's build preset:

```json
{"title": "Example", "output": "…", "exitCode": 0, "truncated": false,
 "elapsedMs": 1234, "artifact": {"name": "output.zip", "data": "UEsDB…", "sha256": "…"}}
```

The command is the `build` list in `projects.json`. A request never supplies arguments. Builds are capped at 90 seconds, run in their own process group with a filtered environment, and are killed as a group. Output is the last 48,000 bytes. When the build succeeds and the project configures an `artifact`, the file is returned inline in base64 with its SHA-256 if it is inside the project and at most 2 MiB; otherwise `artifactError` says why. One build runs per project at a time.

### Jobs

Jobs are the durable form of a build. They keep their state on Linux, so a Mac that disconnects can come back to the same job ID, exit code, logs, and artifact.

- `job-start` — fields `job` (a 32-character hex ID chosen by the client), `project`, and optional `preset` (defaults to `build`). Returns `{"job": …}`. Repeating a start with the same ID and the same project and preset returns the existing job instead of launching a second one, which makes retries safe.
- `job-list` — returns the 50 newest `jobs`.
- `job-status` — field `job`. Returns the job record plus `output`, the last 48,000 bytes of its log, and `truncated`.
- `job-cancel` — field `job`. Marks a queued or running job `cancelling`, sends `SIGTERM` to its process group, and returns the record.
- `job-artifact` — field `job`. Returns `artifact` with `name`, base64 `data`, and `sha256`, re-checked against the recorded digest before it is sent.

A job record carries `id`, `project`, `preset`, `title`, `createdAt`, `updatedAt`, `state`, and, as it progresses, `exitCode`, `elapsedMs`, `truncated`, `error`, `artifactName`, `artifactSha256`, and `artifactError`. States are `queued`, `running`, `cancelling`, `cancelled`, `succeeded`, and `failed`. Jobs run for up to 900 seconds. A job whose supervisor died is reported as failed the next time any client reads it, and the project lock is released, so the preset can be started again.

## Streaming subcommands

A file's bytes do not fit in a JSON request, so transfers and clipboard watching run the receiver with arguments instead. These commands write their own output and do not use the JSON dispatch above, except that a failed upload still answers with the error envelope.

### `--upload` and `--upload-ticket`

The client writes one JSON header line, at most 8,192 bytes, followed by exactly `size` bytes:

```json
{"id": "5d1c…", "name": "report.pdf", "size": 18432, "volume": "home"}
```

`id` is the transfer ticket (32 hex characters), `volume` is `home` or `workspace`, and `sha256` is present for `--upload-ticket`. The file lands in `~/Downloads/Handoff Fox` for `home` and `/workspace/Handoff Fox/Inbox` for `workspace`. A name that is already taken gets part of the ticket appended to the stem: the first 8 characters for `--upload`, the whole ticket for `--upload-ticket`. The reply is the usual envelope with `path` and `sha256`.

`--upload` is the one-shot form: the receiver hashes what it wrote, returns the digest, and the client compares it with its own.

`--upload-ticket` is the durable form and requires `sha256`. It compares the digest before publishing, records a receipt naming the planned destination, and then publishes with a hard link. Repeating the same ticket verifies that the file already at the destination has the same digest and returns the same path, so an interrupted transfer can be retried without a second copy. A different manifest under an existing ticket is refused, as is a different file occupying the planned destination.

### `--download <ticket>`

Writes the queued file to stdout as raw bytes. There is no JSON envelope and no framing; the queued item's `size` and `sha256` in the `pending` reply are the contract. Exits 1 without output when the ticket is no longer queued. The client checks the length and the digest itself.

### `--queue <kind> [value]`

Queues an item for the Mac from the Linux tray. `kind` is `file` (a path), `link` (a URL), `projects`, or `desktop`. Returns `{"handoffs": [item]}`. At most 12 items wait at once. Files are copied into the outbox at queue time, up to 128 MiB, so the original can move afterwards.

### `--run-job` and `--watch-job`

Internal entry points started by `job-start`, with file descriptors passed by inheritance. `--run-job <id> <worker-fd> <project-fd>` starts the monitor, and `--watch-job <id> <worker-fd> <project-fd> <supervisor-fd>` is the process that owns the job's locks and writes its final state. Clients do not call these, and their arguments are file descriptor numbers rather than payloads.

### `--watch-clipboard`

Opens a bidirectional stream for automatic clipboard sharing. Both directions are newline-delimited JSON frames:

```json
{"kind": "ready"}
{"kind": "ping"}
{"kind": "clipboard", "text": "copied text"}
```

The receiver emits `ready` once the clipboard watch is armed. Either side may send `clipboard` frames of at most 64 KiB of text. The receiver suppresses echoes of a value it just wrote, for 3 seconds, so a copy does not bounce back. The stream ends after 28 seconds without a frame from the Mac, or when SSH sends `SIGHUP` or `SIGTERM`. Automatic sharing requires a Wayland session with `wl-copy`; on X11 the stream refuses to start and only manual copy is available.

### `--clipboard-event <marker>`

A helper that `wl-paste --watch` invokes once per selection. It is internal to the receiver, is not part of the wire protocol, and takes a marker file path rather than JSON.

## Limits

| Limit | Value |
| --- | --- |
| JSON request | 420,000 bytes (client sends at most 16,384 except `clipboard-put`) |
| Reply the client will read | 3,500,000 bytes |
| Command output (`build`, `job-status`) | 48,000 bytes, tail |
| Page fetched by `scrape` | 512,000 bytes |
| Artifact | 2 MiB |
| Clipboard text | 64 KiB |
| Transferred file | 128 MiB |
| Upload header line | 8,192 bytes |
| Receiver script the client may install | 131,072 bytes |
| Filename | 220 bytes |
| Project name | 64 characters |
| Saved projects | 50 |
| Outbox | 12 items |
| Browser URL | 4,096 bytes |
| Scrape URL | 2,048 bytes |
| Job runtime | 900 seconds |
| Build action runtime | 90 seconds |

## On-disk layout

Everything the receiver writes belongs to the Linux user. Directories are created with mode `0700` and the process runs with `umask 077`.

Configuration lives in `${XDG_CONFIG_HOME:-~/.config}/desktop-link/projects.json`:

```json
{"projects": [{"id": "…", "name": "Example", "path": "/home/you/work/example",
               "build": ["./ci/test.sh"], "artifact": "build/output.zip",
               "presets": [{"id": "test", "name": "Test", "argv": ["./ci/test.sh"]}]}]}
```

State lives in `${XDG_STATE_HOME:-~/.local/state}/desktop-link/`:

| Path | Contents |
| --- | --- |
| `outbox/<ticket>.json` | `{"id", "kind", "name", "size", "sha256"}` or `{"id", "kind", "url"}` |
| `outbox/<ticket>.bin` | The queued file's bytes |
| `receipts/file-<ticket>.json` | `{"manifest": {"name", "volume", "size", "sha256"}, "path", "delivered"}` |
| `receipts/link-<ticket>.json` | `{"sha256", "delivered"}` |
| `receipts/mac-file-<ticket>.json` | `{"delivered": true}` for files the Mac confirmed |
| `receipts/files.lock`, `links.lock`, `mac-files.lock` | `flock` serialization for each receipt family |
| `jobs/<job>/job.json` | The job record |
| `jobs/<job>/output.log` | The last 48,000 bytes of output |
| `jobs/<job>/artifact.bin` | The collected artifact |
| `jobs/<job>/worker.lock` | Locked by the live worker; a released lock marks a job whose worker stopped |
| `jobs/.lock` | Serializes job state writes |

Receipts are what make retries safe. The receiver writes the planned destination before it publishes a file, and marks `delivered` only after the bytes are in place. The 100 newest Mac file receipts are kept and older ones are deleted. Build locks live beside the configuration as `build-<sha256 of project id>.lock`.

Files the Mac sends are never written outside the two destination folders, and the folder is chosen from the `home` or `workspace` volume the request names. The receiver refuses a volume that is not configured and files that would leave less free space than they need.

## Capability fields

A receiver that predates a capability leaves the field out, and the Mac shows an unchecked state instead of guessing.

- `desktopStatus` is `ready`, `needsGliff`, or `needsHyprland`. `ready` means `gliff-server` is on `PATH` and a Hyprland socket accepts a connection in `XDG_RUNTIME_DIR`.
- `clipboardAvailable` is true when `wl-copy` and `wl-paste` are available in a Wayland session, or `xclip` in an X11 session. It does not mean automatic sharing is armed; that stream is started separately.
- `jobProtocol` is `1` and covers `job-start`, `job-list`, `job-status`, `job-cancel`, and `job-artifact`.
- `transferProtocol` is `1` and means durable tickets exist: `--upload-ticket`, `upload-status`, `deliver-link`, `reveal-upload`, `mac-file-status`, and `ack` behave as described here.

## Evolving this

`VERSION` is compared for equality in both directions. The receiver refuses any request whose version differs, and the Mac refuses any reply whose version differs from the request it sent. There is no negotiation, no minimum, and no compatibility window.

The cost of a bump is the reason it has not happened yet. The Mac installs a receiver only when the command is missing, so a version bump reaches an existing pairing only when the user runs `./script/install_peer.sh` on Linux from a matching checkout. Until they do, every action fails with "Update the Mac and Linux components to the same protocol version." A bump is a coordinated release: change `VERSION` in the receiver and `PeerRequest.version` in the Mac client in the same change, update this document, and say in the release notes that existing pairings need the receiver reinstalled.

Additive changes do not need a bump when an old receiver simply ignores the new thing and every new field is optional on both sides. A new action is safe to add that way; a changed field, a changed default, or a changed meaning is not. If pairing has to survive both a new Mac and an old receiver, the capability fields above are the place to say so, not the version number.
