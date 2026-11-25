---
name: Bug report
about: Something in Handoff Fox did not work on your two machines
title: ""
labels: ""
assignees: ""
---

**Which stage failed**

The preview connects in four steps. Pick the first one that did not pass, then paste the message you saw.

- [ ] Network — the Mac could not reach the Linux address
- [ ] Host trust — the SSH host key was unknown, changed, or did not verify
- [ ] Key sign-in — SSH reached the host but the account refused the key
- [ ] Receiver — SSH worked but the Handoff Fox receiver failed, was missing, or returned an error

**Your setup**

- macOS version and Mac model (for example 15.1 on MacBook Pro M3)
- Linux distro and compositor (for example Omarchy with Hyprland, or Debian 13 with no desktop)
- Gliff installed on Linux: yes / no / not using Open Desktop
- LAN, Tailscale, or another SSH route
- How the Linux host is reached: a saved SSH alias, `user@hostname`, or a jump host
- Handoff Fox version or commit

**What you tried**

Pairing, Open Desktop, Private Screen, Actual size, clipboard, a file or link handoff, a saved project, or a job.

**What happened**

What you expected, and what happened instead. Include the message from the app, and from **Check connection** if you opened it. If the app did not get that far, the last line Terminal printed is the most useful thing you can paste.

```
paste the message here
```

**What you already tried**

For example: re-running `./script/install_peer.sh`, re-pairing, restarting the Mac app, checking `ssh -v` by hand.

**Privacy check**

Remove SSH keys, hostnames, IP addresses, account names, and private file paths from anything you paste or attach.
