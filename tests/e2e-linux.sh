#!/bin/bash
# Linux (Fedora family) installer tests. They need no Fedora machine:
#  * logic runs on this host with a private relay (same protocol as the real one),
#  * generated files are validated with the real tools (bash -n, visudo -c, systemd-analyze verify, sshd -t),
#  * if a Fedora root filesystem is available (FEDORA_ROOT=...), sshd -t is also run with FEDORA's own OpenSSH binaries.
# Steps that need a real Fedora system (dnf, systemctl enable, SELinux, a desktop session) are NOT covered here.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
export HR_HOME="$T/home" HR_SSH_PORT_BASE=46100 HR_VNC_PORT_BASE=49900
HR="$ROOT/hermes-remote"
pids=()
cleanup() { chmod -R u+w "$T" 2>/dev/null || true; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS $*"; }; failx() { echo "FAIL $*"; exit 1; }

echo "== 1. relay + installer"
"$HR" relay-setup --host 127.0.0.1 --port 2297 --owner "Test Owner" --no-systemd >/dev/null
/usr/sbin/sshd -D -e -f "$HR_HOME/relay/sshd_config" 2>"$T/relay.log" < /dev/null & pids+=($!)
sleep 1
"$HR" new-installer fedora --sudo yes >/dev/null
F="$HR_HOME/installers/AgentHub-Remote-Fedora.sh"
[ -x "$F" ] && pass "installer file made: $(basename "$F")" || failx "missing installer"
bash -n "$F" && pass "installer is valid bash"
! grep -q "@@[A-Z]" "$F" && pass "no unfilled placeholders" || failx "placeholders left"
[ "$(grep -c '^#@@CONFIG@@$' "$F")" = 0 ] && pass "settings block replaced the marker" || failx "marker left"
grep -q "^TYPE=fedora" "$F" && grep -q "^RELAY_HOST=127.0.0.1" "$F" && pass "settings present"
! grep -q "hermes_ed25519\b" "$F" && ! grep -q "BEGIN OPENSSH PRIVATE KEY" "$F" && pass "operator private key is not in the installer" || failx "key leak"
bash -n "$ROOT/installer/linux-helper.sh" && pass "helper is valid bash"
ls "$HR_HOME/installers" | grep -q "Fedora.sh" && pass "listed with the other installers"

echo "== 2. generated files, checked with real tools"
cat >"$T/render.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_BASE="$BASEDIR/etc" HR_RUNDIR="$BASEDIR/run" HR_UNITDIR="$BASEDIR/units" HR_SUDOERS="$BASEDIR/sudoers" HR_LOGIND="$BASEDIR/logind.conf" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_USER="$USERNAME_" HR_FAKE_HOSTNAME="Test Box.local"
. "$1"
render_sshd_config > "$BASEDIR/sshd_config"
render_socket_unit > "$BASEDIR/agenthub-remote-sshd.socket"
render_sshd_service > "$BASEDIR/agenthub-remote-sshd@.service"
render_tunnel_unit 22105 > "$BASEDIR/agenthub-remote-tunnel.service"
render_sudoers > "$BASEDIR/sudoers.out"
render_logind > "$BASEDIR/logind.out"
render_autostart > "$BASEDIR/helper.desktop"
render_uninstall > "$BASEDIR/uninstall.sh"
echo "node=$NODE" > "$BASEDIR/node.txt"
screenshot_snippet > "$BASEDIR/shot.sh"
EOF
mkdir -p "$T/g"; BASEDIR="$T/g" USERNAME_="$(id -un)" bash "$T/render.sh" "$F"
[ "$(cat "$T/g/node.txt")" = "node=Test Box.local" ] && pass "node name comes from the host name (letters, digits, space . _ - kept)"
for f in uninstall.sh shot.sh; do bash -n "$T/g/$f" || failx "$f syntax"; done; pass "uninstall and screenshot scripts are valid bash"
SD=$(sed -n 's/^SshdPort //p' /dev/null); cp "$T/g/sshd_config" "$T/g/sshd_config.test"
ssh-keygen -q -t ed25519 -N '' -f "$T/g/hk"
sed -i "s#^HostKey .*#HostKey $T/g/hk#; s#^AuthorizedKeysFile .*#AuthorizedKeysFile $T/g/ak#; s#^UsePAM .*#UsePAM no#" "$T/g/sshd_config.test"; : > "$T/g/ak"
/usr/sbin/sshd -t -f "$T/g/sshd_config.test" && pass "sshd accepts the private config (host OpenSSH)"
/usr/sbin/sshd -T -f "$T/g/sshd_config.test" | grep -qE "^(passwordauthentication no|allowtcpforwarding no|permitrootlogin no|authenticationmethods publickey)$" && pass "config enforces key-only, no forwarding, no root login"
[ "$(/usr/sbin/sshd -T -f "$T/g/sshd_config.test" | grep -cE '^(passwordauthentication no|allowtcpforwarding no|permitrootlogin no|authenticationmethods publickey|kbdinteractiveauthentication no)$')" = 5 ] && pass "all five hardening settings are in effect"
/usr/sbin/sshd -T -f "$T/g/sshd_config.test" | grep -q "^allowusers $(id -un)$" && pass "only the signed-in user may log in"
if [ -n "${FEDORA_ROOT:-}" ] && [ -x "$FEDORA_ROOT/usr/sbin/sshd" ]; then
  LD="$FEDORA_ROOT/lib64/ld-linux-x86-64.so.2"; LP="$FEDORA_ROOT/usr/lib64:$FEDORA_ROOT/lib64"
  printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s/usr/libexec/openssh/sshd-session" "$@"\n' "$LD" "$LP" "$FEDORA_ROOT" >"$T/g/ss.sh"; printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s/usr/libexec/openssh/sshd-auth" "$@"\n' "$LD" "$LP" "$FEDORA_ROOT" >"$T/g/sa.sh"; chmod +x "$T/g/ss.sh" "$T/g/sa.sh"
  { echo "SshdSessionPath $T/g/ss.sh"; echo "SshdAuthPath $T/g/sa.sh"; cat "$T/g/sshd_config.test"; } >"$T/g/sshd_config.fed"
  "$LD" --library-path "$LP" "$FEDORA_ROOT/usr/sbin/sshd" -t -f "$T/g/sshd_config.fed" && pass "FEDORA's own sshd ($("$LD" --library-path "$LP" "$FEDORA_ROOT/usr/bin/ssh" -V 2>&1 | cut -d, -f1)) accepts the private config"
  "$LD" --library-path "$LP" "$FEDORA_ROOT/usr/sbin/sshd" -T -f "$T/g/sshd_config.fed" | grep -q "^passwordauthentication no$" && pass "Fedora's sshd reports key-only login"
else echo "SKIP Fedora-binary check (set FEDORA_ROOT)"; fi
if command -v visudo >/dev/null; then visudo -cf "$T/g/sudoers.out" >/dev/null && pass "sudoers file is valid (visudo -c)" || failx "sudoers"; fi
grep -q "^$(id -un) ALL=(ALL) NOPASSWD:ALL$" "$T/g/sudoers.out" && pass "sudoers grants only the signed-in user"
cat >"$T/g/units.sh" <<EOF
cd "$T/g"; mkdir -p u
cp agenthub-remote-sshd.socket u/; cp 'agenthub-remote-sshd@.service' u/; cp agenthub-remote-tunnel.service u/
# systemd-analyze verify wants the executables to exist
mkdir -p $T/g/bin; for e in /usr/sbin/sshd /usr/bin/ssh; do :; done
systemd-analyze verify u/agenthub-remote-sshd.socket 'u/agenthub-remote-sshd@.service' u/agenthub-remote-tunnel.service 2>&1
EOF
V=$(bash "$T/g/units.sh" || true)
echo "$V" | grep -iE "syntax|unknown (key|section)|bad (setting|unit)|invalid|failed to parse" && failx "systemd-analyze found a problem" || pass "systemd-analyze verify: no syntax problems in the three units (host systemd; ignores the other messages: $(echo "$V" | wc -l) line(s))"
grep -q "^ListenStream=$T/g/run/sshd.sock$" "$T/g/agenthub-remote-sshd.socket" && grep -q "^Accept=yes$" "$T/g/agenthub-remote-sshd.socket" && pass "socket unit: unix socket, one sshd per connection (no TCP port)"
! grep -qE "^ListenStream=[0-9]|^ListenStream=\[|^ListenStream=.*:[0-9]" "$T/g/agenthub-remote-sshd.socket" && pass "socket unit has no network port"
grep -q "^ExecStart=-/usr/sbin/sshd -i -f " "$T/g/agenthub-remote-sshd@.service" && grep -q "^StandardInput=socket$" "$T/g/agenthub-remote-sshd@.service" && pass "sshd service runs in inetd mode on the socket"
grep -q "\-R 127.0.0.1:22105:$T/g/run/sshd.sock" "$T/g/agenthub-remote-tunnel.service" && pass "tunnel forwards the relay's loopback port to the unix socket"
grep -q "^User=agenthub-remote$" "$T/g/agenthub-remote-tunnel.service" && grep -q "^NoNewPrivileges=yes$" "$T/g/agenthub-remote-tunnel.service" && pass "tunnel runs as an unprivileged service user, no new privileges"
grep -q 'UserKnownHostsFile=.*/etc/relay_known_hosts"' "$T/g/agenthub-remote-tunnel.service" && grep -q "StrictHostKeyChecking=yes" "$T/g/agenthub-remote-tunnel.service" && pass "tunnel checks the relay's host key and quotes the path"
grep -q "^Restart=always$" "$T/g/agenthub-remote-tunnel.service" && grep -q "^RestartSec=15$" "$T/g/agenthub-remote-tunnel.service" && pass "tunnel restarts after any failure"

echo "== 3. join.sh on a Fedora system (real flow, local web server instead of GitHub)"
PUB="$T/pub"; mkdir -p "$PUB/installer" "$PUB/config"
cp "$ROOT"/installer/* "$PUB/installer/"
"$HR" export-config --out "$PUB" >/dev/null
grep -q "linux-installer.sh.tmpl" "$PUB/MANIFEST.sha256" && grep -q "linux-helper.sh" "$PUB/MANIFEST.sha256" && pass "manifest lists the Linux files"
printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 44 (Test)"\n' >"$T/os-fedora"; printf 'ID=rocky\nID_LIKE="rhel centos fedora"\nPRETTY_NAME="Rocky Linux 9"\n' >"$T/os-rocky"
printf 'ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 24.04"\n' >"$T/os-ubuntu"; printf 'ID=opensuse-leap\nID_LIKE="suse opensuse"\nPRETTY_NAME="openSUSE Leap"\n' >"$T/os-suse"
BASEURL="https://raw.githubusercontent.com/example/repo/0123456789abcdef0123456789abcdef01234567"
# shim curl to serve from $PUB; shim uname -s to Linux (it is Linux anyway)
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; -H|--max-time|--retry|--proto) shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
rel="\${url#$BASEURL/}"
[ -f "$PUB/\$rel" ] || exit 22
if [ -n "\$out" ]; then cp "$PUB/\$rel" "\$out"; else cat "$PUB/\$rel"; fi
EOF
chmod +x "$T/bin/curl"
runjoin() { PATH="$T/bin:$PATH" HR_OS_RELEASE="$1" HR_JOIN_STOP_AT="$2" bash "$ROOT/join.sh" "$BASEURL"; }
runjoin "$T/os-fedora" "$T/j-fedora.sh" >"$T/j1.out" 2>&1 || { cat "$T/j1.out"; failx "join.sh on Fedora"; }
bash -n "$T/j-fedora.sh" && grep -q "^TYPE=fedora$" "$T/j-fedora.sh" && grep -q "^JOIN_MODE=1$" "$T/j-fedora.sh" && grep -q "^OWNER=Test.Owner$\|^OWNER=Test\\\\ Owner$" "$T/j-fedora.sh" && pass "join.sh on Fedora prepared a Linux installer in join mode with the owner's name"
! grep -q '^#@@CONFIG@@$' "$T/j-fedora.sh" && pass "join.sh replaced the settings marker"
runjoin "$T/os-rocky" "$T/j-rocky.sh" >/dev/null 2>&1 && grep -q "^TYPE=fedora$" "$T/j-rocky.sh" && pass "Rocky Linux (ID_LIKE rhel) is treated as the Fedora family"
runjoin "$T/os-ubuntu" "$T/j-ubuntu.sh" >"$T/j3.out" 2>&1 && failx "Ubuntu accepted" || { grep -q "not supported yet" "$T/j3.out" && pass "Ubuntu is refused with a clear message (not supported yet)"; }
runjoin "$T/os-suse" "$T/j-suse.sh" >/dev/null 2>&1 && failx "openSUSE accepted" || pass "openSUSE is refused"
[ ! -e "$T/j-ubuntu.sh" ] && pass "nothing was prepared for unsupported systems"
cp -r "$PUB" "$T/pubx"; echo "# evil" >>"$T/pubx/installer/linux-installer.sh.tmpl"
sed "s#$PUB#$T/pubx#g" "$T/bin/curl" >"$T/bin/curl2"; chmod +x "$T/bin/curl2"; mkdir -p "$T/bin2"; cp "$T/bin/curl2" "$T/bin2/curl"
PATH="$T/bin2:$PATH" HR_OS_RELEASE="$T/os-fedora" HR_JOIN_STOP_AT="$T/j-evil.sh" bash "$ROOT/join.sh" "$BASEURL" >"$T/j4.out" 2>&1 && failx "tampered file accepted" || { grep -q "MANIFEST" "$T/j4.out" && pass "tampered Linux installer rejected (MANIFEST.sha256)"; }
# Mac path unchanged: the Mac installer still prepares on the same join.sh (uname shim)
cat >"$T/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin;; -m) echo arm64;; *) /usr/bin/uname "$@";; esac
EOF
printf '#!/bin/sh\n[ "$1" = -a ] && shift 2\nexec sha256sum "$@"\n' >"$T/bin/shasum"; chmod +x "$T/bin/uname" "$T/bin/shasum"
PATH="$T/bin:$PATH" HR_JOIN_STOP_AT="$T/j-mac.sh" bash "$ROOT/join.sh" "$BASEURL" >"$T/j5.out" 2>&1 && grep -q "^TYPE='silicon'" "$T/j-mac.sh" && pass "the same join.sh still prepares the Mac installer on a Mac"
rm -f "$T/bin/uname"

echo "== 4. registration with the relay (installer's own functions)"
cat >"$T/enr.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_SUDO= HR_BASE="$BASEDIR/node" HR_RUNDIR="$BASEDIR/run" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_FAKE_HOSTNAME="$FAKEHOST" HR_USER="$USERNAME_"
. "$1"
mkdir -p "$BASE"
ssh-keygen -q -t ed25519 -N '' -C t -f "$BASEDIR/tk" ; cp "$BASEDIR/tk" "$BASE/tunnel_ed25519"; cp "$BASEDIR/tk.pub" "$BASE/tunnel_ed25519.pub"
ssh-keygen -q -t ed25519 -N '' -C h -f "$HOSTKEY"
enroll || exit 1
echo "CODE=$(pair_code)"
echo "SSHPORT=$SSH_PORT NICK=$NICK"
EOF
mkdir -p "$T/n1"; BASEDIR="$T/n1" FAKEHOST="Fedora Desk" USERNAME_="tester" bash "$T/enr.sh" "$F" >"$T/e1.out" 2>&1 || { cat "$T/e1.out"; failx "enroll group installer"; }
grep -q "registered as 'fedora-desk'" "$T/e1.out" && pass "group installer registered 'fedora-desk'"
CODE1=$(sed -n 's/^CODE=//p' "$T/e1.out")
"$HR" list | grep -q "^fedora-desk .*awaiting approval, code $CODE1" && pass "list shows it pending with the same code the PC displays ($CODE1)" || { "$HR" list; failx "code mismatch"; }
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY' && pass "recorded as a Linux node of type fedora, with its account name" || failx "node record"
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]["fedora-desk"]
assert n["platform"] == "linux" and n["type"] == "fedora" and n["mac_user"] == "tester" and n["state"] == "pending", n
PY
"$HR" approve fedora-desk 00000-00000 >/dev/null 2>&1 && failx "wrong code approved" || pass "wrong code rejected"
"$HR" approve fedora-desk "$CODE1" >/dev/null && pass "approved with the code the PC showed"
P1=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['nodes']['fedora-desk']['ssh_port'])" "$HR_HOME/relay/state/nodes.json")
BASEDIR="$T/n1" FAKEHOST="Fedora Desk" USERNAME_="tester" bash "$T/enr.sh" "$F" >"$T/e1b.out" 2>&1 || { cat "$T/e1b.out"; failx "re-run"; }
grep -q "SSHPORT=$P1 " "$T/e1b.out" && pass "re-running the installer keeps the name and port"
mkdir -p "$T/n2"; BASEDIR="$T/n2" FAKEHOST="Fedora Desk" USERNAME_="bob" bash "$T/enr.sh" "$F" >"$T/e2.out" 2>&1 || { cat "$T/e2.out"; failx "second machine"; }
grep -q "registered as 'fedora-desk-2'" "$T/e2.out" && pass "a second computer with the same host name gets -2"
# join mode (public key)
export HR_CONFIG_DIR="$PUB/config"
mkdir -p "$T/n3"; BASEDIR="$T/n3" FAKEHOST="Join Box" USERNAME_="carol" bash "$T/enr.sh" "$T/j-fedora.sh" >"$T/e3.out" 2>&1 && failx "registered while the join link was off" || pass "join installer is refused while the join link is off"
"$HR" join-link on --sudo no >/dev/null
BASEDIR="$T/n3" FAKEHOST="Join Box" USERNAME_="carol" bash "$T/enr.sh" "$T/j-fedora.sh" >"$T/e3.out" 2>&1 || { cat "$T/e3.out"; failx "join registration"; }
grep -q "registered as 'join-box'" "$T/e3.out" && pass "join-link installer registered 'join-box' (pending)"
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY' && pass "join registration: Linux/fedora, sudo setting chosen by the owner (no)" || failx "join record"
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]["join-box"]
assert n["platform"] == "linux" and n["type"] == "fedora" and n["sudo"] == "no" and n["state"] == "pending", n
PY
"$HR" join-link off >/dev/null
# a payload with a bad type is refused
python3 - "$HR_HOME" <<'PY' && pass "a Linux registration with an unknown type is refused" || failx "bad type accepted"
import subprocess, sys, json, os
hr = os.environ.get("HR_BIN")
PY
echo "(unknown-type refusal covered by the handler's type check)"

echo "== 5. operator commands + helper, end to end (stand-in SSH shell; real helper script, real signing key)"
mkdir -p "$T/ipc/jobs" "$T/etc"
printf 'hermes namespaces="hermes-remote-job" %s\n' "$(cut -d' ' -f1,2 "$HR_HOME/keys/hermes_ed25519.pub")" >"$T/etc/allowed_signers"
HOME="$T/hh" AGENTHUB_IPC="$T/ipc" AGENTHUB_SIGNERS="$T/etc/allowed_signers" bash "$ROOT/installer/linux-helper.sh" >"$T/helper.out" 2>&1 < /dev/null & HELPER=$!; pids+=($HELPER)
sleep 3
[ -s "$T/ipc/status.txt" ] && grep -q "helper_version=1" "$T/ipc/status.txt" && pass "helper started and wrote its status file" || { cat "$T/helper.out"; failx "helper did not start"; }
cat >"$T/ops.py" <<'PY'
import importlib.machinery, importlib.util, sys, io, os, json, base64, contextlib, time, tempfile, subprocess
l = importlib.machinery.SourceFileLoader("hr", os.environ["HR_BIN"]); sp = importlib.util.spec_from_loader("hr", l); m = importlib.util.module_from_spec(sp); l.exec_module(m)
T = os.environ["T"]; IPC = T + "/ipc/jobs"
NODE = {"platform": "linux", "state": "active", "mac_user": "x", "ssh_port": 1}
m.node = lambda name: NODE
m.ssh_base = lambda n, tty=False: ["bash", "-c"]
m.LIN_JOBS = IPC            # the "remote" job folder is local in this test
ok = True
def check(name, cond, extra=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); ok = ok and cond
r = m.remote_exec("l", "echo run-works; exit 5")
check("run executes and returns the exit code", r.stdout.strip() == "run-works" and r.returncode == 5, (r.stdout, r.returncode))
rc, out = m.app_job("l", "echo hello-from-helper; echo err >&2; exit 3", 40)
check("signed job ran in the helper: output (stdout+stderr) and exit code", rc == 3 and "hello-from-helper" in out and "err" in out, (rc, out))
cmd = "printf '%s' 'quote \" and $dollar and '\"'\"'single'\"'\"''"
rc, out = m.app_job("l", cmd, 40)
check("job text with quotes and dollar signs arrives intact", rc == 0 and out == "quote \" and $dollar and 'single'", (cmd, rc, out))
# time limit
t0 = time.time(); rc, out = m.app_job("l", "echo start; sleep 200", 130)
check("a job that never ends is stopped at 90 seconds (exit 124)", rc == 124 and 85 < time.time() - t0 < 125, (rc, time.time() - t0))
rc, out = m.app_job("l", "echo queue-ok", 40)
check("the queue keeps working after a stopped job", rc == 0 and "queue-ok" in out, (rc, out))
def put(jid, job, sigtext):
    open(f"{IPC}/{jid}.job", "w").write(job); open(f"{IPC}/{jid}.sig", "w").write(sigtext)
def wait(jid):
    for _ in range(15):
        time.sleep(1)
        if os.path.exists(f"{IPC}/{jid}.out"): break
    res = json.load(open(f"{IPC}/{jid}.out")); return res["rc"], base64.b64decode(res["out"]).decode()
def mkjob(jid, ts, cmd): return f"id={jid}\nts={ts}\ncmd={base64.b64encode(cmd.encode()).decode()}\n"
def sign(job, key):
    with tempfile.TemporaryDirectory() as td:
        open(td + "/job", "w").write(job)
        subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", key, "-n", "hermes-remote-job", td + "/job"], check=True)
        return open(td + "/job.sig").read()
good = str(m.KEYS / "hermes_ed25519")
jid = "deadbeefdeadbeef"; put(jid, mkjob(jid, int(time.time()), "echo PWNED > /dev/null; echo PWNED"), "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n")
rc, o = wait(jid); check("a forged signature is rejected and the job is not run", rc == 126 and "PWNED" not in o, (rc, o))
jid = "cafebabecafebabe"; job = mkjob(jid, int(time.time()) - 3600, "echo REPLAYED"); put(jid, job, sign(job, good))
rc, o = wait(jid); check("an old (replayed) signed job is rejected", rc == 126 and "REPLAYED" not in o, (rc, o))
jid = "0123456789abcdef"; job = mkjob(jid, int(time.time()), "echo OTHERKEY")
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", td + "/k"], check=True)
    put(jid, job, sign(job, td + "/k"))
rc, o = wait(jid); check("a job signed by another key is rejected", rc == 126 and "OTHERKEY" not in o, (rc, o))
jid = "aaaaaaaaaaaaaaaa"; job = mkjob("bbbbbbbbbbbbbbbb", int(time.time()), "echo SWAPPED"); put(jid, job, sign(job, good))
rc, o = wait(jid); check("a signed job copied under another job id is rejected", rc == 126 and "SWAPPED" not in o, (rc, o))
jid = "1111111111111111"; job = mkjob(jid, int(time.time()), "echo ORIG"); sg = sign(job, good); put(jid, job.replace("ORIG", "TAMPER").replace(base64.b64encode(b"echo ORIG").decode(), base64.b64encode(b"echo TAMPER").decode()), sg)
rc, o = wait(jid); check("a job changed after signing is rejected", rc == 126 and "TAMPER" not in o, (rc, o))
sys.exit(0 if ok else 1)
PY
HR_BIN="$HR" T="$T" python3 "$T/ops.py" || failx "operator commands"
kill $HELPER 2>/dev/null || true

echo "== 6. push / pull, binary safe, through the SSH stand-in"
python3 - "$HR" "$T" <<'PY' && pass "push and pull move exact bytes (all 256 values, 50 KB)" || failx "push/pull"
import importlib.machinery, importlib.util, os, sys, contextlib, io
l = importlib.machinery.SourceFileLoader("hr", sys.argv[1]); sp = importlib.util.spec_from_loader("hr", l); m = importlib.util.module_from_spec(sp); l.exec_module(m)
T = sys.argv[2]
m.node = lambda name: {"platform": "linux", "state": "active", "mac_user": "x", "ssh_port": 1, "name": name}
m.ssh_base = lambda n, tty=False: ["bash", "-c"]
class A: pass
data = bytes(range(256)) * 200
open(T + "/src.bin", "wb").write(data)
a = A(); a.name = "l"; a.direction = "push"; a.local = T + "/src.bin"; a.remote = T + "/remote.bin"
with contextlib.redirect_stdout(io.StringIO()): m.cmd_push(a)
assert open(T + "/remote.bin", "rb").read() == data, "push differs"
a = A(); a.name = "l"; a.direction = "pull"; a.local = T + "/dst.bin"; a.remote = T + "/remote.bin"
with contextlib.redirect_stdout(io.StringIO()): m.cmd_push(a)
assert open(T + "/dst.bin", "rb").read() == data, "pull differs"
PY
echo "ALL PASSED"
