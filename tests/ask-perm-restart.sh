#!/bin/bash
# The helper restarts mid-request (macOS "Quit & Reopen" after Screen Recording): installer must re-ask and advance.
set -eu
T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
INST="${1:-$HOME/.hermes-remote/installers/Hermes-Remote-Intel.command}"
export HR_TEST=1 HR_SOURCE_ONLY=1 HR_BASE="$T/b" HR_LOG="$T/l" HR_HOSTKEY_PUB=/dev/null HR_IPC="$T/ipc"
source "$INST"; IPC="$T/ipc"; mkdir -p "$IPC/req" "$IPC/status"
open() { echo "[open $*]"; }
restart_helper() { echo "[helper restarted by installer]"; printf 'boot=3\n' >"$IPC/status.txt"; }
printf 'boot=1\n' >"$IPC/status.txt"
# fake helper: first request -> settings; after the boot id changes it must see a NEW request, then grant
( while [ ! -e "$IPC/req/screen" ]; do sleep 0.2; done; rm -f "$IPC/req/screen"; echo settings >"$IPC/status/screen"
  sleep 2; printf 'boot=2\n' >"$IPC/status.txt"; rm -f "$IPC/status/screen"     # restart wipes in-memory state
  while [ ! -e "$IPC/req/screen" ]; do sleep 0.2; done; echo granted >"$IPC/status/screen" ) &
export -f ask_perm helper_boot restart_helper open say b ok warn 2>/dev/null; out=$(ask_perm screen "Screen Recording" why Privacy_ScreenCapture </dev/null 2>&1 || true)
echo "$out" | grep -q "Screen Recording allowed" && echo "PASS re-asked after helper restart and advanced" || { echo "$out"; echo "FAIL"; exit 1; }
