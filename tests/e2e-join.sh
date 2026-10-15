#!/bin/bash
# End-to-end test of the join flow (setup window, no typed code): relay + fake download host + fake Mac. No sudo, no real Mac.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
export HR_HOME="$T/home" HR_SSH_PORT_BASE=43100 HR_VNC_PORT_BASE=46900
HR="$ROOT/hermes-remote"
pids=()
cleanup() { chmod -R u+w "$T" 2>/dev/null; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS $*"; }; failx() { echo "FAIL $*"; exit 1; }

# --- relay on 2296
"$HR" relay-setup --host 127.0.0.1 --port 2296 --owner "Test Owner" --no-systemd >/dev/null
/usr/sbin/sshd -D -e -f "$HR_HOME/relay/sshd_config" 2>"$T/relay.log" & pids+=($!)
sleep 1

# --- public config exactly as it would be published
PUB="$T/pub"; mkdir -p "$PUB/installer" "$PUB/config"
cp "$ROOT"/installer/* "$PUB/installer/"
"$HR" export-config --out "$PUB" >/dev/null
[ -s "$PUB/config/relay.env" ] && [ -s "$PUB/MANIFEST.sha256" ] && pass "export-config wrote public settings + manifest"
grep -q "hermes_ed25519\b" "$PUB/config/relay.env" && failx "operator private key leaked into public config"
! grep -q "BEGIN OPENSSH" "$PUB/config/relay.env" || true
HERMES_PRIV_B64=$(base64 -w0 "$HR_HOME/keys/hermes_ed25519"); grep -q "$HERMES_PRIV_B64" "$PUB/config/relay.env" && failx "operator key in public config" || pass "operator private key is not in the public config"

# --- fake macOS tools so join.sh runs on this Linux box; curl maps the GitHub URL to $PUB
REF=0123456789abcdef0123456789abcdef01234567
BASE="https://raw.githubusercontent.com/example/agenthub-remote-node/$REF"
mkdir -p "$T/bin"
cat >"$T/bin/uname" <<EOF
#!/bin/sh
case "\$1" in -s) echo Darwin;; -m) echo "\${FAKE_ARCH:-x86_64}";; *) /usr/bin/uname "\$@";; esac
EOF
cat >"$T/bin/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; http*) url="\$1"; shift;; *) shift;; esac; done
case "\$url" in https://api.github.com/repos/*/commits/main) printf '%s' "$REF"; exit 0;; esac
rel="\${url#$BASE/}"; [ "\$rel" != "\$url" ] && [ -f "\${FAKE_PUB:-$PUB}/\$rel" ] || exit 22
cp "\${FAKE_PUB:-$PUB}/\$rel" "\$out"
EOF
cat >"$T/bin/shasum" <<'EOF'
#!/bin/sh
# macOS shasum -a 256 -> GNU sha256sum
[ "$1" = -a ] && shift 2
exec sha256sum "$@"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HR_JOIN_REF="$REF" HR_RAW_BASE="$BASE"

# --- before any window is open the join key must not work at all
grep -q "enroll-join" "$HR_HOME/relay/authorized_keys" && failx "join key active with no window" || pass "join key is not installed while no window is open"

# --- new-join opens a window and prints a pinned command with NO secret in it
OUT=$("$HR" new-join --note "test mac" --sudo no)
echo "$OUT" | grep -q "curl -fsSL $BASE/join.sh | bash -s -- $BASE" && pass "command is pinned to one commit, no code in it" || failx "command: $OUT"
grep -q "enroll-join" "$HR_HOME/relay/authorized_keys" && pass "join key is installed while the window is open"
"$HR" joins | grep -q "^open until" && pass "joins shows the window is open"

# --- join.sh: prepares the installer; tampering is detected
mkdir -p "$T/node"; cp "$ROOT/join.sh" "$T/join.sh"
HR_JOIN_STOP_AT="$T/prepared.command" FAKE_ARCH=arm64 bash "$T/join.sh" "$BASE" >"$T/join.out" 2>&1 || { cat "$T/join.out"; failx "join.sh failed"; }
bash -n "$T/prepared.command" && ! grep -q '@@' "$T/prepared.command" && pass "join.sh prepared a valid installer (arm64)"
grep -q "^JOIN_MODE='1'" "$T/prepared.command" && grep -q "^TYPE='silicon'" "$T/prepared.command" && pass "installer is in join mode and detected the Mac type"
rm -rf "$T/tamper"; cp -r "$PUB" "$T/tamper"; echo "# evil" >>"$T/tamper/installer/mac-installer.sh.tmpl"
FAKE_PUB="$T/tamper" HR_JOIN_STOP_AT="$T/x.command" bash "$T/join.sh" "$BASE" >"$T/tamper.out" 2>&1 && failx "tampered download accepted" || { grep -q "MANIFEST" "$T/tamper.out" && pass "tampered file rejected (manifest mismatch)"; }
bash "$T/join.sh" >/dev/null 2>&1 && failx "missing base accepted" || pass "missing base URL rejected"
bash "$T/join.sh" "https://evil.example/x/$REF" >/dev/null 2>&1 && failx "non-GitHub base accepted" || pass "non-GitHub base URL rejected"
bash "$T/join.sh" "https://raw.githubusercontent.com/example/agenthub-remote-node/main" >/dev/null 2>&1 && failx "unpinned branch accepted" || pass "unpinned base (branch name) rejected"

# --- the Mac enrolls using the prepared installer's own functions
export HR_TEST=1 HR_SOURCE_ONLY=1 HR_BASE="$T/node/base dir" HR_HOSTKEY_PUB="$T/machost.pub" HR_LOG="$T/install.log" HR_FAKE_HOSTNAME="Test MacBook"
ssh-keygen -q -t ed25519 -N '' -f "$T/machost"; mkdir -p "$HR_BASE"
# shellcheck disable=SC1090
source "$T/prepared.command"
S() { chmod u+w "$HR_BASE"; "$@"; local rc=$?; chmod u-w "$HR_BASE"; return $rc; }
make_tunnel_key && write_relay_known_hosts
enroll >/dev/null 2>&1 || { cat "$T/install.log"; failx "enroll while window is open"; }
pass "enrolled while the setup window is open"
read -r SP VP NICK <"$HR_BASE/enrolled"; [ "$NICK" = test-macbook ] && pass "named from hostname: $NICK" || failx "name $NICK"
[ "$SUDO_MODE" = no ] && pass "sudo choice came from the window (no)" || failx "sudo mode '$SUDO_MODE'"
"$HR" list | grep -q "test-macbook.*awaiting approval.*\[test mac\]" && pass "listed as pending with the note" || failx "list: $("$HR" list)"
chmod u+w "$HR_BASE"; enroll >/dev/null 2>&1 && pass "same machine can re-run (repair)" || failx "repair re-run"; chmod u-w "$HR_BASE"

# --- a second, different Mac can also register (pending) while the window is open
ssh-keygen -q -t ed25519 -N '' -f "$T/host2"
( BASE="$T/node2"; HR_BASE="$BASE"; HOSTKEY_PUB_FILE="$T/host2.pub"; HR_FAKE_HOSTNAME="Test MacBook"; mkdir -p "$BASE"; S() { "$@"; }; make_tunnel_key; write_relay_known_hosts; enroll >/dev/null 2>&1 ) && pass "second Mac registers too (pending, distinct name)" || failx "second Mac refused"
"$HR" list | grep -q "test-macbook-2" && pass "same hostname gets -2" || failx "no -2 entry"

# --- the join key can do nothing but register
JK="$HR_HOME/keys/join_ed25519"; KH="$T/rkh"; printf '[127.0.0.1]:2296 %s\n' "$(cut -d' ' -f1,2 "$HR_HOME/relay/ssh_host_ed25519_key.pub")" >"$KH"
JO="-F /dev/null -i $JK -p 2296 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KH"
R=$(echo '{}' | ssh $JO "$USER@127.0.0.1" 'echo SHELL; id' 2>&1 || true); echo "$R" | grep -q "^SHELL\|uid=" && failx "join key got a shell" || pass "join key cannot run commands"
ssh -N $JO -o ExitOnForwardFailure=yes -R 127.0.0.1:43999:127.0.0.1:1 "$USER@127.0.0.1" 2>/dev/null & rp=$!; sleep 2
if kill -0 $rp 2>/dev/null; then kill $rp; failx "join key opened a tunnel"; else pass "join key cannot open tunnels"; fi

# --- per-address limit: a 4th new computer from one address within an hour is refused
R3=refused; R4=refused
for i in 3 4; do
  ssh-keygen -q -t ed25519 -N '' -f "$T/hh$i" 2>/dev/null
  if ( BASE="$T/nn$i"; HR_BASE="$BASE"; HOSTKEY_PUB_FILE="$T/hh$i.pub"; HR_FAKE_HOSTNAME="Extra $i"; mkdir -p "$BASE"; S() { "$@"; }; make_tunnel_key; write_relay_known_hosts; enroll >/dev/null 2>&1 ); then
    [ $i = 3 ] && R3=ok || R4=ok
  fi
done
[ "$R3" = ok ] && [ "$R4" = refused ] && pass "limit: 3 new computers per address per hour (4th refused)" || failx "limit behaviour: 3rd=$R3 4th=$R4"

# --- pending machines are unusable until approved
"$HR" run test-macbook -- /usr/bin/true >/dev/null 2>&1 && failx "pending machine reachable" || pass "pending machine is not usable before approval"

# --- always-on link: no window needed, and join.sh finds the newest commit by itself
"$HR" close-join >/dev/null
"$HR" join-link on >"$T/on.out" 2>&1 && failx "join-link on accepted although config/relay.env is not in this folder" || pass "join-link on refuses when published settings are missing/out of date"
export HR_CONFIG_DIR="$PUB/config"   # the settings as published, not the real repo copy
"$HR" join-link on >/dev/null && pass "join-link on (published settings match the relay)"
grep -q "enroll-join" "$HR_HOME/relay/authorized_keys" && pass "join key installed while the link is on"
"$HR" joins | grep -q "ALWAYS ON" && pass "joins reports ALWAYS ON"
HR_REPO=example/agenthub-remote-node HR_JOIN_STOP_AT="$T/auto.command" FAKE_ARCH=x86_64 bash "$T/join.sh" >"$T/auto.out" 2>&1 || { cat "$T/auto.out"; failx "join.sh without arguments"; }
grep -q "^TYPE='intel'" "$T/auto.command" && pass "no-argument join.sh resolved the newest commit and detected Intel"
# the hourly per-address allowance was used up by the limit test above: clear it so this step tests the always-on link itself
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["join_seen"]=[]; json.dump(d,open(p,"w"))
PY
ssh-keygen -q -t ed25519 -N '' -f "$T/hostA"
( BASE="$T/nA"; HR_BASE="$BASE"; HOSTKEY_PUB_FILE="$T/hostA.pub"; HR_FAKE_HOSTNAME="Always Mac"; mkdir -p "$BASE"; S() { "$@"; }; make_tunnel_key; write_relay_known_hosts; enroll ) >"$T/alw.out" 2>&1 && pass "registers with no window open (link is always on)" || failx "always-on registration refused: $(tail -2 "$T/alw.out")"
"$HR" approve always-mac 00000-00000 >/dev/null 2>&1 && failx "approved with a wrong code" || pass "wrong approval code rejected"
CODEA=$("$HR" list | sed -n 's/^always-mac .*code \([0-9A-F-]*\).*/\1/p'); "$HR" approve always-mac "$CODEA" >/dev/null && pass "approved with the code the Mac showed"
# ids are reused after pending entries expire, so ports never run into each other
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY'
import json,sys,datetime
p=sys.argv[1]; d=json.load(open(p))
old=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=9)).strftime("%Y-%m-%dT%H:%M:%SZ")
for n in d["nodes"].values():
    if n["state"]=="pending": n["enrolled"]=old
json.dump(d,open(p,"w"))
PY
BEFORE=$(python3 -c "import json,sys;print(max(n['id'] for n in json.load(open(sys.argv[1]))['nodes'].values()))" "$HR_HOME/relay/state/nodes.json")
ssh-keygen -q -t ed25519 -N '' -f "$T/hostB"
( BASE="$T/nB"; HR_BASE="$BASE"; HOSTKEY_PUB_FILE="$T/hostB.pub"; HR_FAKE_HOSTNAME="Reuse Mac"; mkdir -p "$BASE"; S() { "$@"; }; make_tunnel_key; write_relay_known_hosts; enroll >/dev/null 2>&1 ) || true
AFTER=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]))['nodes'];print(d['reuse-mac']['id'] if 'reuse-mac' in d else 'none')" "$HR_HOME/relay/state/nodes.json")
[ "$AFTER" != none ] && [ "$AFTER" -le "$BEFORE" ] && pass "freed ids are reused (new id $AFTER <= previous max $BEFORE)" || failx "id not reused: before=$BEFORE after=$AFTER"
"$HR" join-link off >/dev/null; grep -q "enroll-join" "$HR_HOME/relay/authorized_keys" && failx "join key remains after join-link off" || pass "join-link off removes the join key"
"$HR" joins | grep -q "^closed" && pass "joins reports closed"

# --- closing the window stops new registrations but not the machine re-running (repair)
"$HR" close-join >/dev/null
grep -q "enroll-join" "$HR_HOME/relay/authorized_keys" && failx "join key still installed after close" || pass "closing the window removes the join key"
echo "ALL PASSED"
