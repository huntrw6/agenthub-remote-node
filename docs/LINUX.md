# Linux nodes

Status: **written and tested without a Fedora computer.** I did not run a real Fedora install. What was tested:

- The installer logic, the join flow and the registration, on a test relay.
- Every file the installer writes, checked with real tools: `bash -n`, `visudo -c`, `systemd-analyze verify`, and `sshd -t`.
- The private SSH design, with the real **Fedora 44 OpenSSH 10.2** programs and libraries (from Fedora's own image): login through a reverse tunnel into a socket-activated `sshd -i`, a wrong key refused, another user refused.
- The helper and the signed jobs.

Not tested, because they need a real Fedora system: `dnf install`, `systemctl enable`, the `useradd` step, SELinux, and a screenshot in a real desktop session. **Test on one Fedora computer you own before you give the command to anyone.**

## Supported

| | |
|---|---|
| Fedora, RHEL, Rocky Linux, AlmaLinux, CentOS Stream (anything with `ID` or `ID_LIKE` of `fedora`, `rhel` or `centos`) | `fedora` installer |
| x86_64 and aarch64 | yes (the installer detects the CPU) |
| systemd | required |
| Debian, Ubuntu, Arch, openSUSE | not yet (the join command stops with a clear message) |

## Add a computer

Join link (the computer downloads from GitHub). The person pastes this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
```

`join.sh` detects Mac or Linux by itself. On Linux it checks the distribution family.

Or an installer file: `hermes-remote new-installer fedora`, then `hermes-remote serve`. The file is `AgentHub-Remote-Fedora.sh`. The person runs `bash AgentHub-Remote-Fedora.sh`.

The person:
1. Runs the command as their normal user (not as root). It asks for their password when it needs it.
2. Reads the consent text and agrees.
3. Waits. The installer installs what is missing, registers the computer, adds the services and the helper.
4. Reads the approval code to you.

You: `hermes-remote list`, then `hermes-remote approve <name> <code>`, then `hermes-remote doctor <name>`.

## What it installs

| Item | Where | Purpose |
|---|---|---|
| Folder | `/etc/agenthub-remote` (root) | Keys, settings, uninstall script |
| Socket `agenthub-remote-sshd.socket` | a unix socket in `/run/agenthub-remote`. **No network port.** | Starts a private `sshd` for each connection. Key only. Only the signed-in user may log in. |
| Service `agenthub-remote-tunnel` | runs as the user `agenthub-remote` | Holds the outbound connection to the relay. Restarts after any failure. |
| `/etc/sudoers.d/agenthub-remote` | optional (the owner chooses) | Administrator commands without a password prompt |
| Helper | `~/.local/share/agenthub-remote`, autostart at login | Runs signed jobs in the desktop session (screenshots) |
| Power setting | optional, asked | Ignore the laptop lid and idle suspend while plugged in |
| Packages | only if missing | `openssh-server`, `openssh-clients`, `sudo`, and one screenshot tool for the desktop |

The normal SSH server on port 22 is **not** turned on. The computer's own firewall needs no change, because the computer only makes an outbound connection.

The name comes from the host name. Set a nickname later with `hermes-remote nickname`.

## Screenshots

The helper tries these tools in order: `grim` (Sway, Hyprland), `gnome-screenshot` (GNOME), `spectacle` (KDE), `scrot` (X11), `import` (ImageMagick). The installer installs the one that fits the desktop it runs in.

- On **GNOME on Wayland**, the first screenshot can show a permission pop-up. The installer takes a test screenshot during setup, so the person sees it then and can choose Allow.
- On a computer with **no one logged in to the desktop**, or with a locked screen, a screenshot fails. `run` still works.
- A server with no desktop has no screenshots and no helper. That is fine.

## Remove

On the computer, in a terminal:

```bash
sudo /etc/agenthub-remote/uninstall.sh
```

Then on the host: `hermes-remote revoke <name>`. OpenSSH and the screenshot tool stay installed.

## Known limits

- No VNC tunnel. Use `screenshot`, `run` and `gui`.
- If the disk is encrypted (LUKS), the computer waits for the disk password after a restart and stays offline until someone enters it. `doctor` shows a note.
- A laptop suspends on battery or with the lid closed on battery.
- SELinux stays in its normal mode. The services run in default domains. If a connection fails with SELinux on, `diag` shows the mode and recent denials are in `journalctl -t setroubleshoot` or `ausearch -m avc`.
- The installer is a plain shell script. There is no signing step.

## Tests

```bash
FEDORA_ROOT=/path/to/fedora/rootfs bash tests/e2e-linux.sh
```

`FEDORA_ROOT` is optional. It points at an unpacked Fedora image. With it, `sshd -t` also runs with Fedora's own OpenSSH.
