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

## Remaining risks

- The installer has no Apple signature. For `.command` files, Gatekeeper needs right-click and Open. The join link does not need it.
- Anyone who can read `~/.hermes-remote/keys` on the AgentHub host can reach every approved Mac. Keep the folder at mode 700. Do not put it in backups that leave the host without encryption.
- The relay port is open to the internet. Key-only login and the sandbox protect it.
