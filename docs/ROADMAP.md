# Handoff Fox roadmap

The first audience is people who work on a Mac and keep a Linux desktop or workstation nearby or reachable over SSH. The daily workflow is to return to the same machine, send something to it, and pick up an existing project.

## 1. Resume Desktop and make common actions one step

- Remember the last device and its Mirror or Private Screen preference. Keep **Open Desktop** one click from the fox on Mac. Test actual sleep and wake, app restarts, and switching between LAN and Tailscale.
- Add **Check connection** with separate results for network reachability, SSH identity and key sign-in, the receiver, the desktop session, input, and clipboard. Give a specific recovery action for the failing check.
- Bring Linux-to-Mac delivery setup into pairing and show which directions are ready. Let the user confirm the Mac destination from the app.
- Make the existing handoff shortcut on both platforms open a small action panel. Put the last desktop, **Send file or link**, and **Open last project** first. Show the target device beside each action.
- Add **Fit to window**, **Actual size**, and a clear shortcut to release input. Test keyboard layouts, modifiers, scrolling, and mixed display scaling. Reuse the existing Gliff and input backends. [Keyboard layout report](https://github.com/deskflow/deskflow/discussions/9955) · [Mixed display scaling report](https://github.com/deskflow/deskflow/issues/9745)

**Acceptance** — A first-time user pairs within two minutes once SSH is ready. On the supported Mac and Linux pair, they close and wake the Mac and return to the same Linux workspace. From either device they can reach a common action through the existing shortcut.

## 2. Transfer Inbox

- Give files and links a durable ticket and show **Queued**, **Sending**, **Delivered**, or **Retry**. Keep the ticket across app restarts so a retry can resolve to the original delivery receipt.
- Remember each device’s preferred receive folder and display it before sending. Give successful receipts an **Open file** or **Show in folder** action. Add drop-to-send and an explicit screenshot send once the queue can show where the item went. [LocalSend receive-history and drag-and-drop changes](https://github.com/localsend/localsend/blob/main/app/assets/CHANGELOG.md)
- Make automatic clipboard sharing an explicit choice for each paired device. Start with dependable plain text and visible manual paste actions. Validate image and rich-text formats together before enabling them for automatic sharing. [Mixed text and image clipboard report](https://github.com/deskflow/deskflow/issues/10342)

**Acceptance** — Interrupt a transfer, restart the app, and receive one checksum-verified copy in the expected folder. Its receipt opens the correct destination. [Interrupted-transfer request](https://github.com/localsend/localsend/issues/1191)

## 3. Recent Projects and Run on Linux

- Give each recent project shortcuts to its Linux folder, terminal, desktop, and approved build or test presets.
- Give jobs an ID, status, logs, exit code, cancellation, and artifact retrieval. Keep the job and its status on Linux so a Mac disconnect or quit leaves work available to inspect later. [Remote session continuity request](https://github.com/anthropics/claude-code/issues/49790)
- Start with a local CLI for device, project, and job status. Add optional MCP tools for the same operations after the job flow is proven. Keep clipboard, desktop, and job access independently permissioned.

**Acceptance** — Start an approved test preset, close the Mac app, and reopen it to see the same job ID, its actual exit code, logs, and verified artifact. The menu and CLI report the same state.

## Public release readiness

- Choose a project license for the original code and retain third-party notices.
- Build a Developer ID-signed, notarized Mac installer and test it on a clean Mac.
- Publish a support matrix in terms of the actions each setup supports. Start with Omarchy, another Hyprland distro, and a headless SSH host. Record desktop, edge-to-edge input, clipboard, and transfers independently.
- Watch five first-time users pair and complete their first handoff. Ask which action they returned to a week later. Use what they do to pick between richer clipboard formats, native Share menus, and wider compositor support.

[Try the source preview](SETUP.md) · [Share feedback about your setup](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md)
