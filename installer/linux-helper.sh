#!/bin/bash
# AgentHub Remote helper (Linux). Runs hidden in the signed-in user's own desktop session
# (started by the autostart entry at login). Screenshots and anything that needs the desktop must run here,
# not in the SSH session. It runs ONLY jobs that carry a valid signature from the operator key; the list of
# allowed signers is in a folder that only root can change.
set -u
HELPER_VERSION=1
IPC="${AGENTHUB_IPC:-$HOME/.local/share/agenthub-remote/ipc}"
JOBS="$IPC/jobs"
SIGNERS="${AGENTHUB_SIGNERS:-/etc/agenthub-remote/allowed_signers}"
KEYGEN="${AGENTHUB_SSH_KEYGEN:-ssh-keygen}"
MAX_SECONDS=90
MAX_OUT=8388608
mkdir -p "$JOBS"; chmod 700 "$IPC" "$JOBS" 2>/dev/null

# one helper per user
exec 9>"$IPC/lock"
command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }

write_status() {
  printf 'helper_version=%s\nuser=%s\nsession=%s\ndesktop=%s\ndisplay=%s%s\npid=%s\ntime=%s\n' \
    "$HELPER_VERSION" "$(id -un)" "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}" "${DISPLAY:-}" "${WAYLAND_DISPLAY:+ $WAYLAND_DISPLAY}" "$$" "$(date +%FT%T)" >"$IPC/status.txt.tmp" \
    && mv -f "$IPC/status.txt.tmp" "$IPC/status.txt"
}

result() { # id rc outfile
  local out="$JOBS/$1.out"
  printf '{"rc":%s,"out":"%s"}' "$2" "$(head -c "$MAX_OUT" "$3" | base64 -w0)" >"$out.tmp" && mv -f "$out.tmp" "$out"
}
reject() { local t; t="$(mktemp)"; printf '%s' "$2" >"$t"; result "$1" 126 "$t"; rm -f "$t"; }

run_job() {
  local job="$1" id sig ts_now ts_job jid cmd_b64 cmd tmp rc
  id="$(basename "$job" .job)"
  case "$id" in *[!0-9a-f]*|"") rm -f "$job"; return;; esac
  [ "${#id}" = 16 ] || { rm -f "$job"; return; }
  sig="$JOBS/$id.sig"
  if [ ! -f "$sig" ]; then   # the signature arrives just after the job; give up on jobs that never get one
    [ $(( $(date +%s) - $(stat -c %Y "$job") )) -gt 60 ] && rm -f "$job"
    return
  fi
  if ! "$KEYGEN" -Y verify -f "$SIGNERS" -I hermes -n hermes-remote-job -s "$sig" <"$job" >/dev/null 2>&1; then
    rm -f "$job" "$sig"; reject "$id" "rejected: bad or missing signature"; return
  fi
  jid="$(sed -n 's/^id=//p' "$job" | head -1)"; ts_job="$(sed -n 's/^ts=//p' "$job" | head -1)"; cmd_b64="$(sed -n 's/^cmd=//p' "$job" | head -1)"
  rm -f "$job" "$sig"
  ts_now="$(date +%s)"
  case "$ts_job" in *[!0-9]*|"") reject "$id" "rejected: unreadable job"; return;; esac
  if [ "$jid" != "$id" ] || [ $(( ts_now - ts_job )) -gt 600 ] || [ $(( ts_job - ts_now )) -gt 600 ]; then
    reject "$id" "rejected: stale or mismatched job"; return
  fi
  cmd="$(printf '%s' "$cmd_b64" | base64 -d 2>/dev/null)" || { reject "$id" "rejected: unreadable job"; return; }
  tmp="$(mktemp)"
  timeout -k 5 "$MAX_SECONDS" /bin/bash -c "$cmd" >"$tmp" 2>&1 </dev/null; rc=$?
  result "$id" "$rc" "$tmp"; rm -f "$tmp"
}

last=0
while true; do
  now="$(date +%s)"
  if [ $(( now - last )) -ge 30 ]; then write_status; last="$now"; fi
  for j in "$JOBS"/*.job; do [ -e "$j" ] && run_job "$j"; done
  [ -n "${AGENTHUB_ONCE:-}" ] && break
  sleep 1
done
