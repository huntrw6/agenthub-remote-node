# Setup

## 1. Relay (once, on the AgentHub host)

The relay is an unprivileged, sandboxed `sshd`. It runs as a systemd user unit. It accepts only forward-only keys.

```bash
hermes-remote relay-setup --host <dns-name> --port 2222 --owner "<your name>"
```

`--host` must be a DNS name that follows your home IP address (dynamic DNS). Do not use a raw IP address. The command writes `~/.hermes-remote/relay/`, makes the relay host key and the operator key, installs `hermes-remote-relay.service`, and starts it. `--owner` is the name that people see in the installer.

On the router:
1. Reserve the DHCP address of the AgentHub host.
2. Add a port forward: TCP 2222 to the AgentHub host, port 2222.

Check:

```bash
ss -ltn | grep 2222
ssh-keyscan -t ed25519 -p 2222 <dns-name>
```

The second command, run from outside your network, must print the relay key.

## 2. Add a computer: join link (recommended)

The Mac downloads the installer from GitHub. You do not send a file. The repository must be public so the Mac can download it without a login.

Once:

```bash
hermes-remote export-config
git add -A && git commit -m "relay settings" && git push
hermes-remote join-link on
```

`export-config` writes `config/relay.env` and `MANIFEST.sha256`. Run it again, and push, each time you change `installer/` or the relay settings. `join-link on` stops if the pushed settings do not match the relay.

If you use a fork, change `HR_REPO` in `join.sh` to `<you>/<repo>`.

For each Mac, give the person this command:

```bash
curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
```

What happens on the Mac:
1. `join.sh` finds the newest commit on `main`. It downloads every file from that one commit.
2. It checks the files against `MANIFEST.sha256`. It stops if one file is wrong.
3. It detects Intel or Apple silicon and fills in the settings.
4. The guided installer starts (see step 4).

Then:

```bash
hermes-remote list                              # shows the Mac and its approval code
hermes-remote approve <name> <code>             # the code must match the Mac's screen
hermes-remote doctor <name>
hermes-remote nickname <name> <nick>
```

Controls:

| Command | Effect |
|---|---|
| `hermes-remote join-link off` | Closes registration. Computers that are already enrolled are not affected. |
| `hermes-remote join-link on --sudo no` | New Macs do not get passwordless sudo. |
| `hermes-remote new-join --hours 4` | Opens a timed window instead of an always-on link. |
| `hermes-remote joins` | Shows the state and the number of waiting Macs. |

## 3. Add a computer: installer file (no GitHub)

```bash
hermes-remote new-installer intel
hermes-remote new-installer silicon
hermes-remote serve --minutes 60
```

`new-installer` makes one installer for each Mac type in `~/.hermes-remote/installers/`. It is valid for 30 days. A new build stops all older copies. `serve` shows a local-network link with a random token. It stops by itself. For a person who is not on your network, send the zip by another way.

On the Mac: unzip, right-click the `.command` file, select **Open**, select **Open** again.

## 4. What the installer does on the Mac

1. Shows what the user agrees to. Asks for the Mac password.
2. Turns on Remote Login (key only) and Screen Sharing. Sets passwordless sudo for the user (default). Sets "stay awake on power" and "restart after power loss".
3. Installs the tunnel service and tests the connection.
4. Installs the helper app. Asks macOS for each permission in this order. It advances by itself when macOS reports the permission:
   Local Network, Control other apps (System Events, Finder), Desktop/Documents/Downloads, Screen Recording, screen capture approval, Accessibility, Input Monitoring, Full Disk Access.
5. Shows an approval code. The user reads it to you.

For a macOS pop-up: click **Allow**. For a setting: turn on **Hermes Remote Helper**. Press `s` to skip a step.

## Run the installer again

It is safe. The Mac keeps its name and ports. The installer asks if it must skip the permissions that are already set.

## Remove a Mac

On the Mac, in Terminal:

```bash
sudo "/Library/Application Support/HermesRemote/uninstall.sh"
```

Then on the AgentHub host: `hermes-remote revoke <name>`.
