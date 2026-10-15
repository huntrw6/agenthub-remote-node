# Using the nodes

Every command takes a **node** as its first argument. Use the name made from the Mac's computer name (`janes-imac`) or a nickname. A node has one nickname.

```
hermes-remote list
```
```
janes-imac (office)  active  ONLINE  jane  x86_64  15.7.9
```

## Which command for what

| I want to | Command | Notes |
|---|---|---|
| See which computers are enrolled and online | `hermes-remote list` | `ONLINE` means the tunnel is up and the Mac's sshd answers. |
| Run a command | `hermes-remote run <node> -- <argv>` | Runs as the Mac's user over SSH. |
| Run a shell script | `hermes-remote run --sh <node> '<script>'` | Put `--sh` and `--root` before the node. |
| Run as root | `hermes-remote run --root <node> -- <argv>` | Uses `sudo -n`. Works unless the Mac was set up with sudo `no`. |
| Look at the screen | `hermes-remote screenshot <node>` | Saves a PNG in `~/.hermes-remote/shots/` and prints the path. |
| Do something that needs a macOS permission | `hermes-remote gui <node> -- <argv>` or `gui --sh <node> '<script>'` | Runs inside the Hermes Remote Helper app, which holds the permissions. Signed job. 90 second limit. |
| Copy files | `hermes-remote push <node> <local> <remote>` or `pull <node> <remote> <local>` | Uses the SSH connection. |
| Check permissions and power settings | `hermes-remote doctor <node>` | Does not cause macOS pop-ups. |
| Read the report the installer sent | `hermes-remote diag <node>` | Service state and tunnel log from install time. |
| Open a shell | `hermes-remote shell <node>` | Needs a terminal. For a person. |
| Show the Screen Sharing recipe | `hermes-remote vnc <node>` | |
| Give a node a nickname | `hermes-remote nickname <node> <nick>` | |
| Approve a new Mac | `hermes-remote approve <node> <code>` | The code is on the Mac's screen. |
| Remove a Mac | `hermes-remote revoke <node>` | Removes its key and closes its tunnel. |

Examples:

```bash
hermes-remote run office -- /usr/bin/sw_vers
hermes-remote run --sh office 'ps aux | head'
hermes-remote run --root office -- /usr/sbin/systemsetup -getremotelogin
hermes-remote gui --sh office 'osascript -e "tell application \"Finder\" to get name"'
hermes-remote pull office /Users/jane/Desktop/log.txt ./log.txt
```

## Ask AgentHub in chat

AgentHub uses these commands through its terminal tool. Plain requests work:

- "Is the office Mac online? Run doctor on it."
- "Take a screenshot of the office Mac and tell me what is on screen."
- "Run `uptime` on all Macs."
- "Add a new Mac." AgentHub turns on the join link, gives you the command, and asks for the approval code.

## Add and manage computers (operator commands)

| Command | Use |
|---|---|
| `hermes-remote relay-setup --host <dns-name> --port 2222` | Set up the relay (once). |
| `hermes-remote export-config` | Write the public settings that `join.sh` downloads. |
| `hermes-remote join-link on` or `off` or `status` | Turn the always-on join link on or off. `--sudo yes`, `ask` or `no` sets the sudo choice for new Macs. |
| `hermes-remote new-join --hours 4` | Open a timed window and print the command. |
| `hermes-remote close-join` | Close a timed window. |
| `hermes-remote joins` | Show if registration is open and how many Macs wait. |
| `hermes-remote new-installer intel` or `silicon` | Build an installer file without GitHub. |
| `hermes-remote serve --minutes 60` | Serve the installer zips on the local network. |

## Helper app jobs

`gui` puts a signed job in the Mac's helper app. The helper checks the signature with the operator key in a root-owned file. It runs the job with a 90 second limit and returns the output.

Use `gui` for anything that touches a protected resource: the screen, accessibility, Desktop/Documents files, the local network, or app automation. Plain `run` goes through sshd. sshd has no macOS permissions and causes pop-ups.

## Rules

- Do not leave a command running that waits for a macOS pop-up. Take a `screenshot` to see the pop-up.
- Screen recording and remote desktop can mute apps that detect capture. Use `screenshot` to look at the screen.
- Ask the owner before you stop, restart, or change an app that people use.
