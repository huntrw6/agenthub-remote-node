# Troubleshooting

## A Mac shows `offline`

1. Run `hermes-remote diag <node>`. It shows the service state and the tunnel log from install time.
2. On the relay host, run `journalctl --user -u hermes-remote-relay --since -5min`. A repeated "Connection closed [preauth]" every 15 seconds means the Mac connects but fails before login. The cause is host-key trust or a wrong key.
3. Check FileVault. After a restart or a power loss, the Mac waits at the disk-unlock screen. Nothing starts until someone unlocks it.
4. Check for a laptop. It sleeps on battery or with the lid closed. The installer sets "stay awake" for AC power only.
5. Run the installer again on the Mac. It is safe.

## `doctor` shows MISSING for a permission

The probes run inside the helper app. MISSING means the **Hermes Remote Helper** does not have the permission. Run the installer again and answer **no** to "skip permissions". Or open System Settings, Privacy & Security, and turn on the helper. A large macOS update can reset a permission.

## `gui` says the helper did not answer

The helper is busy or blocked. A job that waits for a macOS pop-up blocks the queue until the 90 second limit ends. To restart the helper:

```bash
hermes-remote run <node> -- pkill -f "Hermes Remote Helper.app/Contents/MacOS"
```

A LaunchAgent starts it again. Take a `screenshot` to see a pop-up.

## The join link says "closed"

Registration is off. Run `hermes-remote join-link on`. If it stops with "published settings are out of date", run `export-config`, commit, push, and try again.

## `join.sh` stops with "do not match MANIFEST.sha256"

A file in the repository differs from the list. Run `hermes-remote export-config`, commit, and push. Then try again.

## Lessons from real Macs

- All permissions belong to one named app (Hermes Remote Helper). It appears by name in each Privacy list. Do not use a protected resource through plain SSH. macOS then names `sshd-keygen-wrapper`, which the file picker hides, and shows pop-ups.
- The tunnel service path has a space (`/Library/Application Support/...`). An unquoted `UserKnownHostsFile` made ssh read two arguments and fail the host-key check. The tests use a path with a space.
- `/Library/Application Support/HermesRemote` is owned by root. Every write needs `sudo`. `tests/e2e-local.sh` copies this rule, so a missing `sudo` fails the test.
- In JXA (`osascript -l JavaScript`), `CGPreflightScreenCaptureAccess`, `CGPreflightListenEventAccess` and similar functions are not available until you call `ObjC.bindFunction`. Without it, each check reads "not granted".
- macOS keeps old Screen Recording and Input Monitoring answers inside a running process. Probe from a new child process. Restart the helper after a grant.
- New macOS adds a second approval at the first screen capture ("bypass the system private window picker"). The installer takes a real capture during setup so that the request appears then.
- Automation permission is per target app. The installer asks for System Events and Finder at setup.
- Options such as `permitopen="none"` or a pid file can make sshd reject a key without an error. Test `authorized_keys` options with a real connection.
- Test ports must not overlap with live tunnels (`HR_SSH_PORT_BASE`, `HR_VNC_PORT_BASE`).
