# Security model

The goal is full remote support for machines that the owner controls. The trust limits are about who can reach a machine. They do not limit what AgentHub can do after you approve a machine.

## Keys

| Key | Held by | Can do | Cannot do |
|---|---|---|---|
| Registration key (in `config/relay.env`, public) | Anyone | Send a small, checked registration. It makes a **pending** entry. It works only while the join link is on. | Get a tunnel. Reach any machine. Do anything before you approve the Mac's code. |
| Tunnel key (made on each Mac) | That Mac | Listen on its own two loopback ports on the relay | Open a shell on the relay. Forward other ports. Make local forwards. |
| Operator key (`~/.hermes-remote/keys/hermes_ed25519`) | The AgentHub host only | SSH into approved Macs through their tunnel. Sign helper jobs. | |

The registration key is public on purpose. Its safety comes from approval, not from secrecy.

## Approval

A new Mac shows a 40-bit code (`XXXXX-XXXXX`). The code is a hash of its tunnel public key and its SSH host key. You approve only after the person reads the code to you. The code matches only the Mac that made it.

**Never approve a code that you did not get from a person that you know.** A stranger can register a pending entry while the join link is on. The stranger cannot get access without your approval.

Limits on registration:
- 3 new computers per source address per hour
- 10 pending computers at the same time
- A pending entry is deleted after 7 days
- `hermes-remote join-link off` closes registration at once

## The join link

`join.sh` finds the newest commit of `main` and downloads every file from that one commit. It checks each file against `MANIFEST.sha256`. It stops if a file does not match, or if a file is not in the list.

This protects against a damaged or partial download. It does not protect against a change in the repository itself. Anyone who can write to the repository can change what the Mac runs. Protect the GitHub account with two-factor authentication. Turn the join link off if you suspect a change.

## Relay

- Unprivileged `sshd` as a systemd user unit. It sees only `~/.hermes-remote/relay` (config read-only, `relay/state` writable). It has `ProtectHome=tmpfs`, `NoNewPrivileges`, no capabilities, seccomp and namespace limits, and a 300 MB memory limit.
- Ed25519 keys only. Modern ciphers. Passwords and keyboard-interactive login are off. Root login is off. `MaxStartups 5:50:20`. 15 second login time.
- The relay cannot write its own `authorized_keys`. The registration handler writes state only. The CLI makes the key file under a file lock.
- `revoke` removes the key and closes the live tunnel.

## Host keys, both ways

The installer contains the relay host key. The Mac refuses any other key. AgentHub records each Mac's SSH host key at registration and uses `StrictHostKeyChecking=yes`.

## On the Mac

- `sshd` accepts keys only (`100-hermes-remote.conf`). The operator key is authorized for the installing user.
- Default: passwordless sudo for the installing user. Change it with `--sudo no` or `--sudo ask`. Remove it with `rm /etc/sudoers.d/hermes-remote`. Use it only for people who agreed to full access.
- The helper app is owned by root. Its logic and its trusted signer file are in a root-owned folder. A job needs a valid signature from the operator key, must be less than 10 minutes old, and runs for 90 seconds at most.
- No menu-bar icon. Uninstall works in Terminal only. The consent screen states what the user grants.

## On a Windows PC

- The installer downloads Microsoft's OpenSSH build from the project's GitHub release. The version is fixed and the SHA-256 value is in the installer. A file with another hash is deleted and the install stops.
- It adds a private SSH service named `AgentHubSshd`. It listens on `127.0.0.1:22022` only, so the network cannot reach it. Only the outbound tunnel reaches it. Password login is off. Only the operator key is accepted. It does not change the PC's own OpenSSH Server if one exists.
- The tunnel is a scheduled task that runs as SYSTEM at startup. It makes the same restricted outbound connection as on a Mac.
- Only administrators can change the files in `C:\ProgramData\AgentHubRemote`. The tunnel key and host key are readable by SYSTEM and administrators only.
- The helper runs in the signed-in user's desktop session. It runs a job only if the signature is valid, the job is less than 10 minutes old, and the job id matches. It stops a job after 90 seconds.
- Windows has no `sudo` step: the connection has the rights of the signed-in account. On most home PCs that account is an administrator.
- The installer has no Microsoft signature. For the `.cmd` file, SmartScreen asks for **More info**, then **Run anyway**. The join link does not.

## On a Linux computer

- The private SSH server is **not on the network**. A systemd socket listens on a unix socket in `/run/agenthub-remote`. systemd starts a new `sshd -i` for each connection. Only the outbound tunnel reaches it. Nothing listens on port 22 because of this installer. On Debian and Ubuntu, the installer stops the package system from starting the normal SSH server when it installs `openssh-server`, and turns it off if it installed the package itself.
- The private `sshd` accepts the operator key only, for the signed-in user only (`AllowUsers`). No passwords, no keyboard-interactive login, no root login, no forwarding.
- The tunnel runs as the system user `agenthub-remote` (no login shell, no home folder, `NoNewPrivileges`). It can read only its own key.
- The files in `/etc/agenthub-remote` belong to root. The tunnel key is readable by the tunnel user only.
- Passwordless sudo is the owner's choice at setup (`--sudo yes|ask|no`). It is a separate file, `/etc/sudoers.d/agenthub-remote`, checked with `visudo -c` before it is installed.
- The helper runs in the signed-in user's session. It runs a job only if the signature is valid, the job is less than 10 minutes old, and the job id in the signed text matches the file name. It stops a job after 90 seconds.
- The installer is a plain shell script. `join.sh` checks every file against `MANIFEST.sha256` first.

## Remaining risks

- The installer has no Apple signature. For `.command` files, Gatekeeper needs right-click and Open. The join link does not need it.
- Anyone who can read `~/.hermes-remote/keys` on the AgentHub host can reach every approved Mac. Keep the folder at mode 700. Do not put it in backups that leave the host without encryption.
- The relay port is open to the internet. Key-only login and the sandbox protect it.
