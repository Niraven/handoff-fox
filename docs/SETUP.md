# Build and try Handoff Fox

## What you need

- An Apple Silicon Mac, Xcode Command Line Tools, and Homebrew. The current app targets macOS 14 or later. The preview was built and run on one Apple Silicon Mac.
- A Linux account accessible with an OpenSSH key and Python 3.9 or later. A saved SSH alias can specify a port, identity, or jump host.
- For **Open Desktop**, a running Hyprland session and the Gliff server installed on Linux. Omarchy is the tested desktop. [Gliff Linux setup](https://github.com/omacom/gliff)
- For the optional Linux tray, GTK 4.12 or later and PyGObject. A StatusNotifier tray host displays the icon. The launcher also opens the card directly. [GTK version reference](https://docs.gtk.org/gtk4/method.CssProvider.load_from_string.html)

## Build the Mac app from `main`

```sh
brew install pkg-config gtk4 libadwaita rustup
git clone https://github.com/Niraven/handoff-fox.git
cd handoff-fox
./script/build_and_run.sh --install
```

Have `rustup` and `cargo` on your PATH. The upstream viewer source pins its Rust toolchain. The build verifies a pinned source checksum, compiles the viewer, and installs a Mac app with the viewer inside. The fox uses the existing macOS SSH configuration and registers a user login item.

The preview is for local builds. `./script/build_and_run.sh --package` creates an ad-hoc signed test ZIP for local verification. Developer ID signing and notarization are needed for the planned public Mac installer. [Apple’s signing guidance](https://developer.apple.com/developer-id/)

## Pair and open Linux

1. Click the fox and choose **Pair Linux**. If you already paired a device, open **Send & projects** and click **+**.
2. Enter an SSH alias or `user@hostname`. If the host is new, compare the fingerprint shown by OpenSSH against the one on Linux before accepting it in Terminal.
3. Click **Pair**. Fox installs its receiver under `~/.local/bin` for that Linux account if the receiver is missing.
4. Click **Open Desktop** to mirror the Linux display. **Desktop options** offers a private virtual screen in the same Linux login. **Actual Size** uses one Mac display pixel per stream pixel, clipping the edges if the viewer window is too small. Switching between Fit and Actual Size reopens the viewer and can replace a private virtual screen. The fox remembers the display mode and scale for each device. Press **Shift + Escape** to return viewer input to the Mac.
5. Open **Check connection** for the SSH trust, sign-in, receiver, desktop, clipboard, and input status. Check the SSH fingerprint on the Linux device before accepting it.

If you already installed the receiver with an earlier preview, run `./script/install_peer.sh` on Linux from the same checkout to update it. If you use the Linux tray, update it with `./script/install_omarchy.sh` and reopen it.

## Files, clipboard, and projects

- **Control + Option + J** opens the Mac quick panel for the last desktop, file, link, screenshot, or saved project. On Omarchy, `./script/install_hypr_hotkey.sh` adds **Ctrl + Alt + J** for the Linux quick panel.
- **Send & projects** accepts a dropped file up to 128 MiB or an HTTP or HTTPS link. A current Linux receiver reports delivered items in **Transfer Inbox** and keeps tickets for retries. Use **Save folder** to add a Linux project and open its folder, terminal, or approved presets.
- **Clipboard** provides manual plain-text copy in both directions. Enable **Automatic** for each device you want to share with. An active desktop or configured input pairing is required. Wayland uses `wl-copy` and `wl-paste`.
- For Linux-to-Mac handoffs, install the optional Linux tray using `./script/install_omarchy.sh`. Enable receiving from that device during pairing or under **Check connection**. The Linux quick panel queues files and links while the Mac is away. The Mac defaults to `~/Downloads/Handoff Fox` and lets you choose another folder for that peer.

## Send feedback

Tell us your Mac version, Linux distro and compositor, whether you used LAN or Tailscale, and where you got stuck. [Preview feedback](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md)
