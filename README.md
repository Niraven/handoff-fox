# Handoff Fox

**Your Linux desktop, one click from your Mac.**

Keep your Linux workspace running while you work on your Mac. Click the fox in the menu bar to open the desktop, send a file or link, or jump back into a saved project.

[Build the preview](docs/SETUP.md) · [Read the release notes](https://github.com/Niraven/handoff-fox/releases/tag/v0.1.0-preview.1) · [Tell us what works on your setup](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md)

![Handoff Fox menu bar popover with Open Desktop, Send and projects, and Clipboard controls](docs/images/mac-menu.png)

## What you can do

| When you need to… | Use Handoff Fox to… |
| --- | --- |
| Finish something on Linux | Mirror a running Hyprland desktop or open a separate virtual screen in the same Linux login. |
| Move a file, link, or snippet | Send files and links between the two machines and transfer plain text through the clipboard. |
| Pick up a project or run a job | Open a saved Linux folder or run a build preset you configured there. |

Pairing uses your existing SSH access. The Mac checks the Linux host key and installs a user-level receiver when needed. A Tailscale connection was used in the live desktop test. The Linux machine can also be reached through a verified SSH alias on your network.

## Try the source preview

Start with an **Apple Silicon Mac** and a **Linux machine you can reach with an SSH key**. For desktop control, use a running Hyprland session with Gliff installed. The desktop flow has been exercised on Omarchy. The receiver has also been exercised on a separate Debian SSH setup.

1. [Build and launch Handoff Fox](docs/SETUP.md).
2. Click the fox, pair your Linux SSH address, and select **Open Desktop**.
3. [Share your distro, compositor, and how far you got](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md).

This release ships source for a local build. A downloadable Mac installer needs Developer ID signing and notarization. [Apple’s distribution guidance](https://developer.apple.com/developer-id/)

## What’s next

1. Resume the last desktop and verify wake and network-switch recovery.
2. Show which handoffs are queued, delivered, or ready to retry.
3. Put recent projects and approved Linux jobs one click from the fox.

[Development and upstream updates](docs/DEVELOPMENT.md) · [Third-party notices](dependencies/licenses/README.md)
