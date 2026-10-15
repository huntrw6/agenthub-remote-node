# Windows nodes

Status: **written and tested without a Windows PC.** The scripts parse and lint for Windows PowerShell 5.1. The logic (registration, approval code, signed jobs, file transfer, tampering checks) runs in tests under PowerShell 7 on Linux. The steps that only Windows can run are **not yet tested on a real PC**: the service, the scheduled tasks, the access rules, the screenshot and the first real tunnel. Test on one PC you own before you give the command to anyone.

## Supported

| | |
|---|---|
| Windows 10 version 1809 (build 17763) or later, Windows 11, Server 2019 or later | yes |
| x64 | `win64` installer |
| 32-bit Windows (x32 / x86) | `win32` installer |
| Windows on ARM | runs the x64 installer through emulation; not tested |
| Windows 7, 8, 8.1, older 10 | no |

## Add a PC

Join link (the PC downloads from GitHub):

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.ps1 | iex
```

Or an installer file: `hermes-remote new-installer win64` (or `win32`), then `hermes-remote serve`. The file is `AgentHub-Remote-Windows-x64.cmd` or `AgentHub-Remote-Windows-x32.cmd`.

The person then does this:
1. Reads the consent text and agrees.
2. Chooses **Yes** when Windows asks for administrator permission.
3. Waits. The installer downloads OpenSSH, registers the PC, installs the service, the tunnel task and the helper.
4. Reads the approval code to you.

You run `hermes-remote list`, then `hermes-remote approve <name> <code>`, then `hermes-remote doctor <name>`.

## What it installs

| Item | Where | Purpose |
|---|---|---|
| Folder | `C:\ProgramData\AgentHubRemote` (administrators only) | Keys, settings, OpenSSH, logs, uninstall script |
| Service `AgentHubSshd` | listens on `127.0.0.1:22022` | Private SSH server for the operator key. Starts with Windows. |
| Task `AgentHubRemoteTunnel` | runs as SYSTEM at startup | Keeps the outbound connection to the relay open. Restarts after a failure. |
| Task `AgentHubRemoteHelper` | runs hidden at sign-in, as the user | Runs signed jobs in the desktop session (screenshots). |
| Power setting | optional, asked | No sleep and no hibernate while plugged in |

The name of the PC comes from its computer name. Set a nickname later with `hermes-remote nickname`.

## Remove

On the PC, in an administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\ProgramData\AgentHubRemote\uninstall.ps1"
```

Then on the host: `hermes-remote revoke <name>`. The uninstall script leaves the power settings as they are.

## Known limits

- No remote desktop (VNC) tunnel. Use `screenshot` and `gui`.
- A screenshot needs someone signed in with an unlocked screen.
- `run --root` is not used. Commands run with the rights of the signed-in account.
- An account with a Microsoft sign-in name can have a different short name. If `run` says `Permission denied`, run `hermes-remote doctor` and check `signed_in_user`.
- Antivirus products can block an unsigned installer. Allow it, or ask the owner.
- Updating the helper: push `installer/win-helper.ps1` to `C:/ProgramData/AgentHubRemote/helper.ps1` with `hermes-remote push`, then restart the task `AgentHubRemoteHelper`.

## Tests

```bash
PWSH=/path/to/pwsh bash tests/e2e-windows.sh
```

It needs PowerShell 7 (`pwsh`). It checks: installer building, line endings and ASCII, PowerShell parse and lint (5.1 rules), the approval code (PowerShell and server must match), `join.ps1` (tampering, missing files, branch names, other hosts), registration for x64 and x32 and join mode, name collisions, re-runs, command quoting, long scripts, file transfer in both directions, and the helper (signed jobs run; forged, replayed and wrong-key jobs are refused).
