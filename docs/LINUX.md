# Linux nodes

Status: **written and tested without a real Fedora, Debian or Ubuntu computer.** What was tested:

- The installer logic, the join flow and the registration, on a test relay.
- Every file the installer writes, checked with real tools: `bash -n`, `visudo -c`, `systemd-analyze verify`, and `sshd -t`.
- The private SSH design, with the real OpenSSH programs and libraries from each distribution's own image: **Fedora 44 (OpenSSH 10.2), Debian 13 (OpenSSH 10.0) and Ubuntu 24.04 (OpenSSH 9.6)**. Each one: login through a reverse tunnel into a socket-activated `sshd -i`, a wrong key refused, another user refused.
- The Debian and Ubuntu package scripts, run for real in their images: what `apt install openssh-server` enables, which files it makes, and the `/run/sshd` directory that `sshd` needs.
- The helper and the signed jobs.

Not tested, because they need a real system: `dnf install` and `apt install` on a live computer, `systemctl enable`, the `useradd` step, SELinux and AppArmor, and a screenshot in a real desktop session. **Test on one computer of each family that you own before you give the command to anyone.**

## Supported

| | |
|---|---|
| Fedora, RHEL, Rocky Linux, AlmaLinux, CentOS Stream (anything with `ID` or `ID_LIKE` of `fedora`, `rhel` or `centos`) | `fedora` installer |
| Debian, Ubuntu, Linux Mint, Pop!_OS, Raspberry Pi OS and others based on them (`ID` or `ID_LIKE` of `debian` or `ubuntu`) | `debian` installer |
| x86_64 and aarch64 | yes (the installer detects the CPU) |
| systemd | required |
| Arch, openSUSE, Alpine and others | not yet (the join command stops with a clear message) |

## Add a computer

Join link (the computer downloads from GitHub). The person pastes this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
```

`join.sh` detects Mac or Linux by itself. On Linux it checks the distribution family and picks the right installer.

Or an installer file: `hermes-remote new-installer fedora` or `new-installer debian`, then `hermes-remote serve`. The files are `AgentHub-Remote-Fedora.sh` and `AgentHub-Remote-Debian.sh`. The person runs `bash AgentHub-Remote-Debian.sh` (or the Fedora one). An installer for the wrong family stops with a message that names the right one.

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
| Packages | only if missing | `openssh-server`, the SSH client (`openssh-clients` on Fedora, `openssh-client` on Debian), `sudo`, and one screenshot tool for the desktop |

The normal SSH server on port 22 is **not** turned on. The computer's own firewall needs no change, because the computer only makes an outbound connection.

**Debian and Ubuntu difference.** On those systems, installing `openssh-server` starts and enables the normal SSH server on port 22 at once. The installer blocks that: it puts a temporary `policy-rc.d` file in place while `apt-get` runs (a file that tells the package system not to start services), then removes it. It also turns off `ssh.service` and `ssh.socket` after it installed the package itself. If the computer already had `openssh-server`, the installer does not touch the computer's own SSH services. Check with `hermes-remote diag <node>`: the line `stock_ssh_port22` shows `off` when nothing listens on port 22.

Another Debian difference: `sshd` will not run as root without the folder `/run/sshd`. The private service creates it itself (`RuntimeDirectory=sshd`).

The name comes from the host name. Set a nickname later with `hermes-remote nickname`.

## Screenshots

The helper tries the desktop screenshot portal first on Wayland (GNOME needs this; it asks, then waits up to 60 s for the new picture to appear, so a first-time Allow works), then these tools in order: `grim` (Sway, Hyprland), `gnome-screenshot` (GNOME), `spectacle` (KDE), `scrot` (X11), `import` (ImageMagick). The installer installs the one that fits the desktop it runs in.

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
- SELinux (Fedora family) and AppArmor (Debian family) stay in their normal modes. The services run in default domains. If a connection fails, `diag` shows the mode. Recent SELinux denials: `sudo ausearch -m avc -ts recent`. AppArmor denials: `sudo journalctl -k | grep -i apparmor`.
- The installer is a plain shell script. There is no signing step.
- On Debian and Ubuntu, the account must be in the `sudo` group. On Fedora, in the `wheel` group. If it is not, the installer says so and stops before it changes anything.
- Ubuntu **Server** and Debian without a desktop have no screenshots and no helper. `run`, `push` and `pull` work.

## Tests

```bash
FEDORA_ROOT=/path/to/fedora DEBIAN_ROOT=/path/to/debian UBUNTU_ROOT=/path/to/ubuntu bash tests/e2e-linux.sh
```

The three variables are optional. Each one points at an unpacked distribution image (for example from the Fedora or Docker Hub registry). With them, the test also runs that distribution's own OpenSSH for the tunnel login. Without them, those checks are skipped.
