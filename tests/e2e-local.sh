#!/bin/bash
# Local end-to-end simulation: relay sshd + fake "Mac" sshd + real installer functions.
# No sudo, no macOS needed. Uses a throwaway HR_HOME and ports 2299 (relay) / 2298 (fake Mac).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; export HR_HOME="$T/home" HR_SSH_PORT_BASE=42100 HR_VNC_PORT_BASE=45900
HR="$ROOT/hermes-remote"
pids=()
cleanup() { chmod -R u+w "$T" 2>/dev/null;  [ -n "${KEEP:-}" ] && { cp "$T/relay.log" /tmp/relay.log 2>/dev/null; cp "$T/home/relay/authorized_keys" /tmp/ak 2>/dev/null; };  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS $*"; }; failx() { echo "FAIL $*"; exit 1; }

# fake Mac: its own sshd + host key, authorizes whatever is in $T/mac_authorized_keys
mkdir -p "$T/mac"; ssh-keygen -q -t ed25519 -N '' -f "$T/mac/hostkey"
cat >"$T/mac/sshd_config" <<EOF
Port 2298
ListenAddress 127.0.0.1
HostKey $T/mac/hostkey
PidFile $T/mac/pid
AuthorizedKeysFile $T/mac/authorized_keys
PasswordAuthentication no
UsePAM no
EOF
/usr/sbin/sshd -D -e -f "$T/mac/sshd_config" 2>"$T/mac/log" & pids+=($!)

if [ "${E2E_SYSTEMD:-0}" = 1 ]; then
  # exercise the real sandboxed user unit (test name + port, separate state)
  export HR_UNIT=hermes-remote-relay-test
  "$HR" relay-setup --host 127.0.0.1 --port 2299 >/dev/null || failx "sandboxed unit failed to start"
  trap 'systemctl --user disable --now hermes-remote-relay-test.service >/dev/null 2>&1; rm -f ~/.config/systemd/user/hermes-remote-relay-test.service; systemctl --user daemon-reload; cleanup' EXIT
  sleep 2; systemctl --user is-active hermes-remote-relay-test.service >/dev/null && pass "sandboxed relay unit active" || { journalctl --user -u hermes-remote-relay-test -n 20 --no-pager; failx "unit not active"; }
else
  HR_HOME="$HR_HOME" "$HR" relay-setup --host 127.0.0.1 --port 2299 --no-systemd >/dev/null
  /usr/sbin/sshd -D -e -f "$HR_HOME/relay/sshd_config" 2>"$T/relay.log" & pids+=($!)
  sleep 1
fi
"$HR" new-installer intel --owner Tester >/dev/null
INST="$HR_HOME/installers/Hermes-Remote-Intel.command"
[ ! -e "$HR_HOME/installers/Hermes-Remote-AppleSilicon.command" ] && pass "only the requested type generated"
bash -n "$INST" && pass "installer parses (bash -n)"
grep -q '@@' "$INST" && failx "unreplaced placeholders" || pass "no unreplaced placeholders"

# run the installer's real enrollment functions against the relay
export HR_TEST=1 HR_SOURCE_ONLY=1 HR_BASE="$T/node with space" HR_HOSTKEY_PUB="$T/mac/hostkey.pub" HR_LOG="$T/install.log"
mkdir -p "$HR_BASE"
export HR_FAKE_HOSTNAME="Janes iMac"
# shellcheck disable=SC1090
source "$INST"
# emulate a root-owned $BASE: writable ONLY through S (sudo). A plain redirect into it must fail.
S() { chmod u+w "$HR_BASE"; "$@"; local rc=$?; chmod u-w "$HR_BASE"; return $rc; }
chmod u-w "$HR_BASE"
( : >"$HR_BASE/should-fail" ) 2>/dev/null && failx "BASE is writable without sudo: test would miss root-owned-dir bugs" || pass "test BASE emulates a root-owned directory"
make_tunnel_key && write_relay_known_hosts && pass "tunnel key + relay known_hosts"
enroll && pass "enrollment accepted by relay"; read -r _ _ NICK <"$HR_BASE/enrolled" || { cat "$T/install.log" "$T/relay.log"; failx enroll; }
CODE="$(pair_code)"
"$HR" list | grep -q "awaiting approval, code $CODE" && pass "relay shows same pairing code ($CODE)" || failx "code mismatch"
enroll >/dev/null 2>&1 && pass "re-run idempotent"
[ "$NICK" = janes-imac ] && pass "node named from hostname: $NICK" || failx "name was '$NICK'"
# a second Mac with the same hostname via the SAME installer gets a distinct name + ports
ssh-keygen -q -t ed25519 -N '' -f "$T/mac2host"
( BASE="$T/node2"; HOSTKEY_PUB_FILE="$T/mac2host.pub"; HR_BASE="$BASE"; mkdir -p "$BASE"; S() { "$@"; }; make_tunnel_key; write_relay_known_hosts; enroll >/dev/null 2>&1; read -r P1 P2 N2 <"$HR_BASE/enrolled"; echo "$N2 $P1" >"$T/second" )
grep -q '^janes-imac-2 ' "$T/second" && pass "same installer, same hostname -> janes-imac-2 (distinct ports)" || { cat "$T/second"; failx "second machine"; }
"$HR" nickname janes-imac-2 office-mac >/dev/null && "$HR" list | grep -q "janes-imac-2 (office-mac)" && pass "nickname set after enrollment" || failx nickname
"$HR" approve janes-imac "ZZZZZ-ZZZZZ" 2>/dev/null && failx "wrong code accepted" || pass "wrong code rejected"
"$HR" approve janes-imac "$(echo "$CODE" | tr 'A-Z' 'a-z')" >/dev/null && pass "approve with correct code"

# repair: active Mac re-running installer keeps its ports; different key is refused
enroll >/dev/null 2>&1 && pass "active Mac re-run (repair) accepted"
cp "$HR_BASE/tunnel_ed25519.pub" "$T/keep.pub"; ssh-keygen -q -t ed25519 -N '' -f "$T/other"; S cp "$T/other.pub" "$HR_BASE/tunnel_ed25519.pub"
enroll >/dev/null 2>&1 && failx "different key accepted for active mac" || pass "active Mac with a different key refused"
S cp "$T/keep.pub" "$HR_BASE/tunnel_ed25519.pub"

# ---- permission prompts: fake helper app grants "lan" after a pending phase, "fda" via Settings ----
export HR_IPC="$T/ipc"; IPC="$HR_IPC"; mkdir -p "$HR_IPC/req" "$HR_IPC/status" "$HR_IPC/jobs"
fake_helper() {
  while true; do
    for r in "$HR_IPC"/req/*; do [ -e "$r" ] || continue; k=$(basename "$r"); rm -f "$r"
      case "$k" in
        lan) echo pending >"$HR_IPC/status/lan"; sleep 2; echo granted >"$HR_IPC/status/lan";;
        capture) echo pending >"$HR_IPC/status/capture"; sleep 2; echo granted >"$HR_IPC/status/capture";;
        fda) echo settings >"$HR_IPC/status/fda"; sleep 2; echo granted >"$HR_IPC/status/fda";;
      esac
    done
    for j in "$HR_IPC"/jobs/*.job; do [ -e "$j" ] || continue; id=$(basename "$j" .job); [ -e "$HR_IPC/jobs/$id.sig" ] || continue
      if ssh-keygen -Y verify -f "$T/allowed_signers" -I hermes -n hermes-remote-job -s "$HR_IPC/jobs/$id.sig" <"$j" >/dev/null 2>&1; then
        cmd=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['cmd'])" "$j"); o=$(bash -c "$cmd" 2>&1); rc=$?
        python3 -c "import json,sys,base64;print(json.dumps({'rc':int(sys.argv[1]),'out':base64.b64encode(sys.argv[2].encode()).decode()}))" "$rc" "$o" >"$HR_IPC/jobs/$id.out"
      else echo '{"rc":126,"out":"cmVqZWN0ZWQ="}' >"$HR_IPC/jobs/$id.out"; fi
      rm -f "$j" "$HR_IPC/jobs/$id.sig"
    done; sleep 0.3
  done
}
printf 'hermes namespaces="hermes-remote-job" %s\n' "$(awk '{print $1" "$2}' "$HR_HOME/keys/hermes_ed25519.pub")" >"$T/allowed_signers"
fake_helper </dev/null >/dev/null 2>&1 & pids+=($!)
out=$(ask_perm lan "Local Network" "why" Privacy_LocalNetwork </dev/null 2>&1) && echo "$out" | grep -qi "click Allow" && echo "$out" | grep -q "Local Network allowed" && pass "pop-up permission: detected granted and advanced automatically" || { echo "$out"; failx "ask_perm lan"; }
out=$(ask_perm fda "Full Disk Access" "why" Privacy_AllFiles </dev/null 2>&1); echo "$out" | grep -q "Hermes Remote Helper" && echo "$out" | grep -q "Full Disk Access allowed" && pass "settings permission: guided, then advanced when granted" || { echo "$out"; failx "ask_perm fda"; }
WHY=$(grep -o 'ask_perm capture "Screen capture approval" "[^"]*"' "$INST" | sed 's/^ask_perm capture "Screen capture approval" "//; s/"$//')
echo "$WHY" | grep -qi "private window picker" || failx "installer does not explain the window-picker prompt"
out=$(ask_perm capture "Screen capture approval" "$WHY" Privacy_ScreenCapture </dev/null 2>&1); echo "$out" | grep -qi "private window picker" && echo "$out" | grep -q "Screen capture approval allowed" && pass "screen capture approval: explained, detected, advanced" || { echo "$out"; failx "ask_perm capture"; }
rm -f "$HR_IPC/status/nope"; : >"$HR_IPC/req/nope"
# signed jobs through hermes-remote gui (needs the tunnel to the fake Mac: runs against the fake sshd)
HR_DIAG_TEXT=$'selftest=ok\nline2' enroll >/dev/null 2>&1; "$HR" diag janes-imac | grep -q "selftest=ok" && pass "installer health report stored on relay" || failx "diag"
# the installer's own connection self-test (base path has a space) must trust the relay
ST="$(tunnel_selftest)"; echo "$ST" | grep -qi "host key\|known" && { echo "$ST"; failx "selftest host key"; } || pass "installer self-test trusts the relay"
# the REAL LaunchDaemon arguments (path contains a space, like /Library/Application Support) must connect
tunnel_plist >"$T/t.plist" && python3 -c "import plistlib;plistlib.load(open('$T/t.plist','rb'))" && pass "LaunchDaemon plist is valid" || failx "plist invalid"
# authorize AgentHub on the fake Mac, then bring the tunnel up exactly like the LaunchDaemon does
cp "$HR_HOME/keys/hermes_ed25519.pub" "$T/mac/authorized_keys"
SSHP=$(python3 -c "import json,os;print(json.load(open(os.environ['HR_HOME']+'/relay/state/nodes.json'))['nodes']['janes-imac']['ssh_port'])")
python3 - "$T/t.plist" "$SSHP" 2298 >"$T/args" <<'PY'
import plistlib, sys
a = plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"]
a = [x.replace(f"127.0.0.1:{sys.argv[2]}:127.0.0.1:22", f"127.0.0.1:{sys.argv[2]}:127.0.0.1:{sys.argv[3]}") for x in a]
a = [x.replace("RELAYUSER", "") for x in a]
print("\0".join(a), end="")
PY
mapfile -d '' ARGV <"$T/args"
"${ARGV[@]}" 2>"$T/tunnel.log" & pids+=($!)
sleep 2
kill -0 "${pids[-1]}" 2>/dev/null && pass "tunnel stays up" || { cat "$T/tunnel.log"; failx tunnel; }
"$HR" list | grep -q ONLINE && pass "list shows ONLINE" || failx "not online"
OUT=$("$HR" run janes-imac -- echo hello-from-node) && [ "$OUT" = hello-from-node ] && pass "hermes-remote run works through tunnel" || failx "run: $OUT"
"$HR" run --sh janes-imac 'echo $((6*7))' | grep -q 42 && pass "run --sh" || failx "run --sh"
echo data >"$T/f.txt"; "$HR" push janes-imac "$T/f.txt" "$T/pushed.txt" && [ "$(cat "$T/pushed.txt")" = data ] && pass "push" || failx push
"$HR" pull janes-imac "$T/pushed.txt" "$T/pulled.txt" && [ "$(cat "$T/pulled.txt")" = data ] && pass "pull" || failx pull

# security: tunnel key must NOT give a shell on the relay or forward other ports
ssh -F /dev/null -i "$HR_BASE/tunnel_ed25519" -p 2299 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$HR_BASE/relay_known_hosts" "$USER@127.0.0.1" 'echo SHELL' 2>&1 | grep -q '^SHELL' && failx "tunnel key got a shell" || pass "tunnel key has no shell"
ssh -N -F /dev/null -i "$HR_BASE/tunnel_ed25519" -p 2299 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$HR_BASE/relay_known_hosts" -o ExitOnForwardFailure=yes -R 127.0.0.1:22999:127.0.0.1:1 "$USER@127.0.0.1" 2>/dev/null &
rp=$!; sleep 2; if kill -0 $rp 2>/dev/null; then kill $rp; failx "tunnel key forwarded an unlisted port"; else pass "tunnel key cannot forward unlisted ports"; fi

# signed job through the helper: queue -> verify signature -> run -> result (fake sshd shares this user's HOME)
JD="$HOME/Library/Application Support/HermesRemote"; mkdir -p "$HOME/Library/Application Support"
[ -e "$JD" ] && failx "refusing to overwrite existing $JD"
mkdir -p "$JD" && ln -s "$T/ipc" "$JD/ipc"
trap 'rm -f "$JD/ipc"; rmdir "$JD" 2>/dev/null; true' RETURN 2>/dev/null
GUI_OUT=$("$HR" gui --sh janes-imac 'echo from-helper-$((20+22))' 2>&1) && [ "$GUI_OUT" = from-helper-42 ] && pass "signed job ran inside helper" || { echo "$GUI_OUT"; failx "gui job"; }
# forged job (wrong key) must be rejected by the helper
ssh-keygen -q -t ed25519 -N '' -f "$T/evil"; printf '{"id":"deadbeefdeadbeef","ts":%s,"cmd":"touch %s/pwned"}' "$(date +%s)" "$T" >"$T/ipc/jobs/deadbeefdeadbeef.job"
ssh-keygen -q -Y sign -f "$T/evil" -n hermes-remote-job "$T/ipc/jobs/deadbeefdeadbeef.job"; mv "$T/ipc/jobs/deadbeefdeadbeef.job.sig" "$T/ipc/jobs/deadbeefdeadbeef.sig"
sleep 2; [ ! -e "$T/pwned" ] && pass "forged job rejected by helper" || failx "forged job ran"
rm -f "$JD/ipc"; rmdir "$JD" 2>/dev/null; true

"$HR" revoke janes-imac >/dev/null
sleep 1
ssh -N -F /dev/null -i "$HR_BASE/tunnel_ed25519" -p 2299 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$HR_BASE/relay_known_hosts" -R "127.0.0.1:$SSHP:127.0.0.1:2298" "$USER@127.0.0.1" 2>/dev/null &
rp=$!; sleep 2; if kill -0 $rp 2>/dev/null; then kill $rp; failx "revoked key still works"; else pass "revoked key rejected"; fi
echo "ALL PASSED"
