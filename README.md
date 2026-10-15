# agenthub-remote-node

AgentHub uses these tools to control remote computers. A user runs one command on a Mac. AgentHub then connects to the Mac through the internet.

The Mac makes an outbound connection to a relay on the AgentHub host. The Mac does not accept incoming connections.

```
Mac  --outbound TCP 2222-->  relay (AgentHub host)  <--ssh--  hermes-remote
```

## Requirements

AgentHub host:
- Linux with systemd user services
- Python 3.9 or later
- OpenSSH (`ssh`, `sshd`, `ssh-keygen`)
- A router that forwards TCP port 2222 to the host
- A DNS name that points to your home IP address

Remote computer: macOS 15 or later (Intel and Apple silicon), Windows 10 version 1809 or later (x64 and x32), or Linux of the Fedora family (Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream).

## Install

```bash
git clone https://github.com/huntrw6/agenthub-remote-node.git
cd agenthub-remote-node
./install.sh
bash tests/e2e-local.sh
bash tests/e2e-join.sh
PWSH=/path/to/pwsh bash tests/e2e-windows.sh   # needs PowerShell 7 (pwsh)
bash tests/e2e-linux.sh
```

Each test must show `ALL PASSED`.

## Set up the relay (once)

```bash
hermes-remote relay-setup --host <dns-name> --port 2222 --owner "<your name>"
```

Then forward TCP port 2222 on the router to the host. See `docs/SETUP.md`.

## Add a computer

1. Turn on the join link (once):
   ```bash
   hermes-remote export-config
   git add -A && git commit -m "relay settings" && git push
   hermes-remote join-link on
   ```
2. Give the person this command. They paste it in Terminal on the Mac or Linux computer:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
   ```
3. The Mac shows an approval code. The person reads it to you.
4. Approve it:
   ```bash
   hermes-remote list
   hermes-remote approve <name> <code>
   hermes-remote doctor <name>
   ```
   Each line of `doctor` must show `OK`.

To turn the link off: `hermes-remote join-link off`.

For a Windows PC, the person pastes this in PowerShell instead:
   ```powershell
   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.ps1 | iex
   ```
   Windows asks for administrator permission, then shows an approval code. Windows is not tested on a real PC yet. See `docs/WINDOWS.md`.

On Linux the same `join.sh` command works: it detects the system. Only the Fedora family is supported so far, and it is not tested on a real Fedora computer yet. See `docs/LINUX.md`.

If you use a fork, change `HR_REPO` in `join.sh` and `join.ps1` and the addresses above to your fork.

Without GitHub: use `hermes-remote new-installer intel` (or `silicon`, `win64`, `win32`, `fedora`) and `hermes-remote serve`. See `docs/SETUP.md`.

## Use

```bash
hermes-remote list
hermes-remote run <node> -- <command>
hermes-remote screenshot <node>
hermes-remote gui --sh <node> '<script>'
```

Use the node name or its nickname. See `docs/USAGE.md` for all commands.

## Warning

Some apps mute audio or show a pop-up when macOS reports screen recording. Screen recording and remote desktop cause this. Screenshots do not.

## Secrets

The folder `~/.hermes-remote` holds all private keys and the node list. This repository does not contain them. Make a backup of this folder. See `docs/RESTORE.md`.

The file `config/relay.env` is public by design. It holds the relay address and a registration key. The key cannot do anything until you approve a code. See `docs/SECURITY.md`.

## Files

| Path | Content |
|---|---|
| `hermes-remote` | The command-line tool |
| `join.sh` | The script that the join link runs on a Mac or a Linux computer |
| `join.ps1` | The script that the join link runs on a Windows PC |
| `installer/` | The macOS, Windows and Linux installer templates and helpers |
| `config/relay.env` | Public relay settings (made by `export-config`) |
| `install.sh` | Checks requirements and installs the tool |
| `tests/` | Tests that need no Mac |
| `docs/` | Usage, setup, Windows, Linux, restore, security, troubleshooting |
