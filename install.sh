#!/bin/bash
# Install hermes-remote on the AgentHub host: checks prerequisites, links the CLI onto PATH.
# Safe to re-run. Does not create keys or open ports (that is `hermes-remote relay-setup`).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${HR_BIN_DIR:-$HOME/.local/bin}"
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  MISSING %s\n' "$*"; miss=1; }
miss=0

echo "prerequisites:"
[ "$(uname -s)" = Linux ] && ok "Linux" || bad "Linux host (the relay uses systemd user units)"
command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' && ok "python3 $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" || bad "python3 >= 3.9"
for c in ssh ssh-keygen; do command -v $c >/dev/null && ok "$c" || bad "$c (openssh-client)"; done
[ -x /usr/sbin/sshd ] && ok "/usr/sbin/sshd" || bad "/usr/sbin/sshd (openssh-server; the service is not enabled system-wide, the relay runs its own copy)"
[ -x /usr/bin/python3 ] && ok "/usr/bin/python3 (used by the sandboxed enrollment handler)" || bad "/usr/bin/python3 (system python; the sandbox cannot see other pythons)"
command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1 && ok "systemd user session" || bad "systemd user session (loginctl enable-linger $USER, then log in again)"
[ $miss -eq 0 ] || { echo "Fix the MISSING items and re-run."; exit 1; }

mkdir -p "$BIN"
chmod +x "$HERE/hermes-remote" "$HERE/tests/"*.sh "$HERE/tools/"*.sh 2>/dev/null || true
ln -sfn "$HERE/hermes-remote" "$BIN/hermes-remote"
echo "linked $BIN/hermes-remote -> $HERE/hermes-remote"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not on PATH; add it to your shell profile";; esac

# the installer is rendered from files next to the script: confirm they are all present
for f in installer/mac-installer.sh.tmpl installer/helper.js installer/launcher.js; do
  [ -f "$HERE/$f" ] || { echo "MISSING repo file: $f"; exit 1; }
done
"$BIN/hermes-remote" --help >/dev/null && echo "hermes-remote runs."
echo "next: bash tests/e2e-local.sh   |   hermes-remote relay-setup --host <ddns-name> --port 2222   (docs/SETUP.md)"
