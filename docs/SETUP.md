# Build and try Handoff Fox

## What you need

- An Apple Silicon Mac, Xcode Command Line Tools, and Homebrew. The current app targets macOS 14 or later. The preview was built and run on one Apple Silicon Mac.
- A Linux account accessible with an OpenSSH key and Python 3.9 or later. A saved SSH alias can specify a port, identity, or jump host.
- For **Open Desktop**, a running Hyprland session and the Gliff server installed on Linux. Omarchy is the tested desktop. [Gliff Linux setup](https://github.com/omacom/gliff)
- For the optional Linux tray, GTK 4.12 or later and PyGObject. A StatusNotifier tray host displays the icon. The launcher also opens the card directly. [GTK version reference](https://docs.gtk.org/gtk4/method.CssProvider.load_from_string.html)

## Install the Mac preview

```sh
brew install pkg-config gtk4 libadwaita rustup
git clone https://github.com/Niraven/handoff-fox.git
cd handoff-fox
git switch --detach v0.1.0-preview.1
./script/build_and_run.sh --install
```

Have `rustup` and `cargo` on your PATH. The upstream viewer source pins its Rust toolchain. The build verifies a pinned source checksum, compiles the viewer, and installs a Mac app with the viewer inside. The fox uses the existing macOS SSH configuration and registers a user login item.

The preview is for local builds. `./script/build_and_run.sh --package` creates an ad-hoc signed test ZIP for local verification. Developer ID signing and notarization are needed for the planned public Mac installer. [Apple’s signing guidance](https://developer.apple.com/developer-id/)

## Pair and open Linux

1. Click the fox and choose **Pair Linux**. If you already paired a device, open **Send & projects** and click **+**.
2. Enter an SSH alias or `user@hostname`. If the host is new, compare the fingerprint shown by OpenSSH against the one on Linux before accepting it in Terminal.
3. Click **Pair**. Fox installs its receiver under `~/.local/bin` for that Linux account if the receiver is missing.
4. Click **Open Desktop** to mirror the Linux display. Use **Desktop options** for **Private screen**, which creates a separate virtual monitor in the same Linux login. Press **Shift + Escape** to return viewer input to the Mac.

## Files, clipboard, and projects

- **Send & projects** sends a file up to 128 MiB or opens an HTTP or HTTPS link on Linux. Use **Save folder** to add a Linux project. Choose **Open on Linux** to reopen it in the Linux file manager.
- **Clipboard** provides manual plain-text copy in both directions. Automatic clipboard sharing uses the existing configured input pairing with a verified host. Wayland uses `wl-copy` and `wl-paste`.
- For Linux-to-Mac handoffs, install the optional Linux tray using `./script/install_omarchy.sh` on Linux. On the Mac, set `defaults write local.desktoplink.control initialLinuxPeer -string 'linux-host'` with your verified SSH alias, then restart Handoff Fox. The tray’s **Send to Mac** action queues delivery. The Mac receives files in `~/Downloads/Handoff Fox`.
- **Control + Option + J** opens Mac handoff. On Omarchy, `./script/install_hypr_hotkey.sh` adds a Linux shortcut for **Ctrl + Alt + J**.

## Send feedback

Tell us your Mac version, Linux distro and compositor, whether you used LAN or Tailscale, and where you got stuck. [Preview feedback](https://github.com/Niraven/handoff-fox/issues/new?template=preview-feedback.md)
