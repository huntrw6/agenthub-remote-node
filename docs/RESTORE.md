# Restoring or moving the system

This repository contains no private keys. A new host needs the code (this repository) and the state folder `~/.hermes-remote/`. Find your case below.

## Case A: new system, no Macs enrolled

Nothing to restore. Follow `SETUP.md` from step 1. `relay-setup` makes the keys.

## Case B: move AgentHub to a new host and keep every Mac

Each Mac trusts the relay host key and DNS name that were put in its installer. The relay trusts each Mac's tunnel key. To keep all Macs online, restore the whole state folder.

On the old host (do this on a schedule; the copy is the key to every Mac, so keep it private):

```bash
tar -C ~ -czf hermes-remote-state.tgz .hermes-remote
chmod 600 hermes-remote-state.tgz
```

On the new host:

```bash
git clone https://github.com/huntrw6/agenthub-remote-node.git
cd agenthub-remote-node && ./install.sh
tar -C ~ -xzf hermes-remote-state.tgz
chmod -R go-rwx ~/.hermes-remote
hermes-remote relay-setup
hermes-remote list
```

Then point the DNS name and the router forward (TCP 2222) at the new host. The Macs reconnect in about one minute.

The state folder:

| Path | Content |
|---|---|
| `relay/ssh_host_ed25519_key` | The relay identity. Macs refuse a different one. |
| `keys/hermes_ed25519` | The operator key. It is authorized on every Mac. It also signs helper jobs. |
| `keys/join_ed25519` | The registration key for the join link. Its public form is in `config/relay.env`. |
| `relay/state/nodes.json` | Names, ports, tunnel keys, Mac host keys, nicknames. |
| `installers/` | Built installers. Rebuild them at any time. |

## Case C: state lost

The Macs cannot be reached. They trust keys that you no longer have. Do this for each Mac:

1. Run `relay-setup`, `export-config`, push, and `join-link on` (or `new-installer`).
2. Run the new installer on the Mac. It replaces its own tunnel service and helper. The Mac registers as a new pending node.
3. Approve the new code.
4. Remove the old entries with `hermes-remote revoke`.

## Change the DNS name or the relay host key

Installers contain the DNS name and the relay host key. After a change, run `export-config`, push, and run the installer again on every Mac.

## Update after a code change

Run `export-config`, commit, and push. Macs that are already enrolled keep working. They need the new installer only when the installer or the helper app must change.

To update the helper app logic on one Mac without the installer:

```bash
hermes-remote push <node> installer/helper.js /tmp/h.js
hermes-remote run --root <node> -- install -m 0644 -o root -g wheel /tmp/h.js "/Library/Application Support/HermesRemote/helper.js"
```
