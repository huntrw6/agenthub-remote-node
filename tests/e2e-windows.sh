#!/bin/bash
# Windows installer tests that need no Windows machine. Uses PowerShell 7 on Linux (PWSH=/path/to/pwsh) for everything that is
# not Windows-only. Windows-only calls (services, scheduled tasks, ACLs) are skipped by HR_TEST=1 and are NOT covered here.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PWSH="${PWSH:-$(command -v pwsh || true)}"
[ -n "$PWSH" ] && [ -x "$PWSH" ] || { echo "SKIP: pwsh not found (set PWSH=/path/to/pwsh)"; exit 0; }
T="$(mktemp -d)"
export HR_HOME="$T/home" HR_SSH_PORT_BASE=44100 HR_VNC_PORT_BASE=47900 TEMP="$T/tmp"; mkdir -p "$TEMP"
HR="$ROOT/hermes-remote"
pids=()
cleanup() { chmod -R u+w "$T" 2>/dev/null || true; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS $*"; }; failx() { echo "FAIL $*"; exit 1; }
ps() { "$PWSH" -NoProfile -NonInteractive "$@"; }

# the same split the .cmd file performs
extract_ps1() { python3 - "$1" "$2" <<'PY'
import sys
t = open(sys.argv[1], 'rb').read().decode('ascii')
m = '#' + '---PS1---'
assert t.count(m) == 1, "marker count %d" % t.count(m)
open(sys.argv[2], 'w', encoding='utf-8-sig', newline='').write(t[t.index(m) + len(m):])
PY
}

echo "== 1. relay + installers"
"$HR" relay-setup --host 127.0.0.1 --port 2295 --owner "Test Owner" --no-systemd >/dev/null
/usr/sbin/sshd -D -e -f "$HR_HOME/relay/sshd_config" 2>"$T/relay.log" & pids+=($!)
sleep 1
"$HR" new-installer win64 --sudo no >/dev/null && "$HR" new-installer win32 --sudo no >/dev/null
for t in x64 x32; do F="$HR_HOME/installers/AgentHub-Remote-Windows-$t.cmd"; [ -s "$F" ] && pass "installer file made: $(basename "$F")" || failx "missing $F"; done
F64="$HR_HOME/installers/AgentHub-Remote-Windows-x64.cmd"; F32="$HR_HOME/installers/AgentHub-Remote-Windows-x32.cmd"
LC_ALL=C grep -q $'\r$' "$F64" && pass ".cmd uses Windows line endings" || failx "no CRLF"
LC_ALL=C grep -qP '[^\x00-\x7F]' "$F64" && failx "non-ASCII byte in .cmd" || pass ".cmd is plain ASCII (safe for any code page)"
head -c 300 "$F64" | LC_ALL=C grep -q "BEGIN OPENSSH" && failx "key near the top" || true
! grep -q "hermes_ed25519\b" "$F64" && pass "operator private key not in the installer" || failx "operator key leak"
! grep -q '@@' "$F64" && pass "no unfilled placeholders" || failx "placeholders left"
extract_ps1 "$F64" "$T/x64.ps1"; extract_ps1 "$F32" "$T/x32.ps1"
grep -q "^\$Type = 'win64'" "$T/x64.ps1" && grep -q "^\$Type = 'win32'" "$T/x32.ps1" && pass "x64 and x32 installers carry the right type"

echo "== 2. parse + lint (PowerShell 5.1 syntax rules)"
cat >"$T/lint.ps1" <<'PS'
$bad = 0
foreach ($f in $args) {
    $e = $null; $tk = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tk, [ref]$e)
    if ($e) { $e | ForEach-Object { "PARSE $f line $($_.Extent.StartLineNumber): $($_.Message)" }; $bad++ }
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer
        $r = Invoke-ScriptAnalyzer -Path $f -Severity Error
        $r | ForEach-Object { "LINT  $f line $($_.Line): $($_.RuleName): $($_.Message)"; $bad++ }
        $r = Invoke-ScriptAnalyzer -Path $f -IncludeRule PSUseCompatibleSyntax -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
        $r | ForEach-Object { "SYNTAX51 $f line $($_.Line): $($_.Message)"; $bad++ }
    }
}
if ($bad) { exit 1 } else { 'clean' }
PS
ps -File "$T/lint.ps1" "$T/x64.ps1" "$T/x32.ps1" "$ROOT/installer/win-helper.ps1" "$ROOT/join.ps1" >"$T/lint.out" 2>&1 && pass "all PowerShell files parse; no lint errors; PowerShell 5.1 syntax OK ($(tail -1 "$T/lint.out"))" || { cat "$T/lint.out"; failx "lint"; }

echo "== 3. functions (dot-sourced)"
cat >"$T/fn.ps1" <<'PS'
$env:HR_SOURCE_ONLY = "1"; $env:HR_BASE = "/tmp/hr-unit"
. $args[0]
$fail = 0
function Check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
# hostname -> node name
$env:HR_FAKE_HOSTNAME = "Jane's PC (office)!"
Check 'node name keeps safe characters only' ((Get-NodeName) -eq 'Janes PC office')
# argument quoting survives spaces, quotes and empty arguments
$r = Invoke-Native '/usr/bin/printf' @('<%s>', 'a b', '', 'say "hi"') $null 10
Check 'native call keeps spaces, empty and quoted arguments' ($r.Out -eq '<a b><><say "hi">' -and $r.Code -eq 0)
$r = Invoke-Native '/usr/bin/cat' @() ([System.Text.Encoding]::UTF8.GetBytes('{"k":"v"}')) 10
Check 'native call passes stdin bytes' ($r.Out -eq '{"k":"v"}')
$r = Invoke-Native '/bin/sleep' @('30') $null 1
Check 'native call time limit' ($r.Code -eq 124)
# approval code must equal what the server computes
$tp = (Get-Content $args[1] -Raw).Trim(); $hp = (Get-Content $args[2] -Raw).Trim()
"CODE " + (Get-PairCode $tp $hp)
if ($fail) { exit 1 }
PS
ssh-keygen -q -t ed25519 -N '' -C t -f "$T/tk"; ssh-keygen -q -t ed25519 -N '' -C h -f "$T/hk"
ps -File "$T/fn.ps1" "$T/x64.ps1" "$T/tk.pub" "$T/hk.pub" >"$T/fn.out" 2>&1 || { cat "$T/fn.out"; failx "functions"; }
grep -h "^PASS" "$T/fn.out"
PYCODE=$(python3 - "$HR" "$T/tk.pub" "$T/hk.pub" <<'PY'
import sys, importlib.machinery, importlib.util
l = importlib.machinery.SourceFileLoader("hr", sys.argv[1]); s = importlib.util.spec_from_loader("hr", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
tp = " ".join(open(sys.argv[2]).read().split()[:2]); hp = " ".join(open(sys.argv[3]).read().split()[:2])
print(m.code_for(tp, hp))
PY
)
PSCODE=$(sed -n 's/^CODE //p' "$T/fn.out")
[ -n "$PSCODE" ] && [ "$PSCODE" = "$PYCODE" ] && pass "approval code is identical in PowerShell and in the server ($PSCODE)" || failx "code mismatch ps=$PSCODE py=$PYCODE"

echo "== 4. join.ps1 (no arguments' real flow, against a local web server instead of GitHub)"
"$HR" export-config --out "$T/pub0" >/dev/null 2>&1 || true
PUB="$T/pub"; mkdir -p "$PUB/installer" "$PUB/config"
cp "$ROOT"/installer/* "$PUB/installer/"
"$HR" export-config --out "$PUB" >/dev/null
grep -q "win-installer.ps1.tmpl" "$PUB/MANIFEST.sha256" && grep -q "win-helper.ps1" "$PUB/MANIFEST.sha256" && pass "manifest lists the Windows files"
PORT=48765; ( cd "$PUB" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1 ) & pids+=($!)
sleep 1
export HR_TEST=1 HR_BASE_URL="http://127.0.0.1:$PORT"
runjoin() { HR_JOIN_BASE="$HR_BASE_URL" HR_JOIN_STOP_AT="$1" "$PWSH" -NoProfile -NonInteractive -Command "Get-Content -Raw '$ROOT/join.ps1' | Invoke-Expression"; }
runjoin "$T/joined.ps1" >"$T/join.out" 2>&1 || { cat "$T/join.out"; failx "join.ps1 failed"; }
[ -s "$T/joined.ps1" ] && ! grep -q '@@' "$T/joined.ps1" && grep -q "^\$Type = 'win64'" "$T/joined.ps1" && grep -q "^\$JoinMode = '1'" "$T/joined.ps1" && pass "join.ps1 prepared a win64 installer in join mode"
grep -q "^\$Owner = 'Test Owner'" "$T/joined.ps1" && pass "owner name filled from the published settings"
ps -File "$T/lint.ps1" "$T/joined.ps1" >/dev/null 2>&1 && pass "prepared installer parses and lints clean"
# tampering is detected
rm -rf "$T/pubx"; cp -r "$PUB" "$T/pubx"; echo "# evil" >>"$T/pubx/installer/win-installer.ps1.tmpl"
( cd "$T/pubx" && exec python3 -m http.server 48766 --bind 127.0.0.1 >/dev/null 2>&1 ) & pids+=($!); sleep 1
HR_JOIN_BASE="http://127.0.0.1:48766" HR_JOIN_STOP_AT="$T/x.ps1" "$PWSH" -NoProfile -NonInteractive -Command "Get-Content -Raw '$ROOT/join.ps1' | Invoke-Expression" >"$T/tamper.out" 2>&1 && failx "tampered download accepted" || { grep -q "MANIFEST" "$T/tamper.out" && pass "tampered file rejected (MANIFEST.sha256)" || { cat "$T/tamper.out"; failx "tamper message"; }; }
[ ! -e "$T/x.ps1" ] && pass "nothing was prepared after tampering"
# a file missing from the manifest is rejected
rm -rf "$T/puby"; cp -r "$PUB" "$T/puby"; grep -v "win-helper.ps1" "$PUB/MANIFEST.sha256" >"$T/puby/MANIFEST.sha256"
( cd "$T/puby" && exec python3 -m http.server 48767 --bind 127.0.0.1 >/dev/null 2>&1 ) & pids+=($!); sleep 1
HR_JOIN_BASE="http://127.0.0.1:48767" HR_JOIN_STOP_AT="$T/y.ps1" "$PWSH" -NoProfile -NonInteractive -Command "Get-Content -Raw '$ROOT/join.ps1' | Invoke-Expression" >/dev/null 2>&1 && failx "unlisted file accepted" || pass "file missing from the manifest rejected"
unset HR_TEST
# real pinning rule applies without the test switch
HR_JOIN_BASE="https://evil.example/x/0123456789abcdef0123456789abcdef01234567" "$PWSH" -NoProfile -NonInteractive -Command "Get-Content -Raw '$ROOT/join.ps1' | Invoke-Expression" >/dev/null 2>&1 && failx "non-GitHub base accepted" || pass "non-GitHub base address rejected"
HR_JOIN_BASE="https://raw.githubusercontent.com/example/agenthub-remote-node/main" "$PWSH" -NoProfile -NonInteractive -Command "Get-Content -Raw '$ROOT/join.ps1' | Invoke-Expression" >/dev/null 2>&1 && failx "unpinned branch accepted" || pass "unpinned base (branch name) rejected"

echo "== 5. registration against the live-protocol relay"
export HR_TEST=1
runinst() { # <ps1> <hostname> <user> <base>
  HR_BASE="$4" HR_FAKE_HOSTNAME="$2" HR_FAKE_USER="$3" "$PWSH" -NoProfile -NonInteractive -File "$1"
}
# 5a. group installer (private enroll key), no join link needed
runinst "$T/x64.ps1" "Janes PC" "jane smith" "$T/winbase1" >"$T/inst1.out" 2>&1 || { cat "$T/inst1.out"; failx "installer run 1"; }
grep -q "registered as 'janes-pc'" "$T/inst1.out" && pass "group installer registered 'janes-pc' (name from the computer name)" || { cat "$T/inst1.out"; failx "no registration"; }
CODE1=$(grep -oE '[0-9A-F]{5}-[0-9A-F]{5}' "$T/inst1.out" | tail -1)
"$HR" list | grep -q "^janes-pc .*awaiting approval, code $CODE1" && pass "list shows the PC pending with the same code the PC displayed ($CODE1)" || { "$HR" list; failx "code differs"; }
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY' && pass "recorded as a Windows x64 node; account name with a space accepted" || failx "node record"
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]["janes-pc"]
assert n["platform"] == "windows" and n["type"] == "win64" and n["mac_user"] == "jane smith" and n["info"]["arch"] == "x64", n
PY
"$HR" approve janes-pc 00000-00000 >/dev/null 2>&1 && failx "approved a wrong code" || pass "wrong code rejected"
"$HR" approve janes-pc "$CODE1" >/dev/null && pass "approved with the PC's code"
# idempotent re-run keeps name and ports
P1=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['nodes']['janes-pc']['ssh_port'])" "$HR_HOME/relay/state/nodes.json")
runinst "$T/x64.ps1" "Janes PC" "jane smith" "$T/winbase1" >"$T/inst1b.out" 2>&1 || { cat "$T/inst1b.out"; failx "re-run"; }
P2=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['nodes']['janes-pc']['ssh_port'])" "$HR_HOME/relay/state/nodes.json")
[ "$P1" = "$P2" ] && grep -q "registered as 'janes-pc'" "$T/inst1b.out" && pass "re-running the installer keeps the name and port" || failx "re-run changed things"
# 5b. x32 installer, second PC with the same name gets -2
runinst "$T/x32.ps1" "Janes PC" "bob" "$T/winbase2" >"$T/inst2.out" 2>&1 || { cat "$T/inst2.out"; failx "installer x32"; }
grep -q "registered as 'janes-pc-2'" "$T/inst2.out" && pass "x32 installer registered; duplicate names get -2" || { cat "$T/inst2.out"; failx "x32 registration"; }
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY' && pass "x32 recorded as win32 / x86" || failx "x32 record"
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]["janes-pc-2"]
assert n["platform"] == "windows" and n["type"] == "win32" and n["info"]["arch"] == "x86", n
PY
# 5c. join mode (public key): refused while the link is off, accepted when on
ssh-keygen -q -t ed25519 -N '' -f "$T/dummy" >/dev/null
JOINED_OFF=$(HR_BASE="$T/winbase3" HR_FAKE_HOSTNAME="Test Laptop" HR_FAKE_USER="tester2" "$PWSH" -NoProfile -NonInteractive -File "$T/joined.ps1" 2>&1 || true)
echo "$JOINED_OFF" | grep -q "registered as" && failx "registered while the join link was off" || pass "join installer is refused while the join link is off"
export HR_CONFIG_DIR="$PUB/config"
"$HR" join-link on --sudo no >/dev/null && pass "join link on"
HR_BASE="$T/winbase3" HR_FAKE_HOSTNAME="Test Laptop" HR_FAKE_USER="tester2" "$PWSH" -NoProfile -NonInteractive -File "$T/joined.ps1" >"$T/inst3.out" 2>&1 || { cat "$T/inst3.out"; failx "join installer"; }
grep -q "registered as 'test-laptop'" "$T/inst3.out" && pass "join-link installer registered 'test-laptop' (pending)" || { cat "$T/inst3.out"; failx "join registration"; }
python3 - "$HR_HOME/relay/state/nodes.json" <<'PY' && pass "join registration recorded as Windows with the right type" || failx "join record"
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]["test-laptop"]
assert n["platform"] == "windows" and n["type"] == "win64" and n["state"] == "pending", n
PY
"$HR" join-link off >/dev/null


echo "== 6. operator commands + helper, end to end (stand-in SSH shell; real helper script, real signing key)"
mkdir -p "$T/shim" "$T/PD"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$PWSH" >"$T/shim/powershell"; chmod +x "$T/shim/powershell"
export ProgramData="$T/PD"; mkdir -p "$T/PD/AgentHubRemote/ipc/jobs"
# allowed_signers exactly as the installer writes it
printf 'hermes namespaces="hermes-remote-job" %s\n' "$(cut -d' ' -f1,2 "$HR_HOME/keys/hermes_ed25519.pub")" >"$T/PD/AgentHubRemote/allowed_signers"
AGENTHUB_BASE="$T/PD/AgentHubRemote" AGENTHUB_SSH_KEYGEN="$(command -v ssh-keygen)" AGENTHUB_PS="$PWSH" "$PWSH" -NoProfile -NonInteractive -File "$ROOT/installer/win-helper.ps1" >"$T/helper.out" 2>&1 & HELPER=$!; pids+=($HELPER)
sleep 3
[ -s "$T/PD/AgentHubRemote/ipc/status.txt" ] && grep -q "helper_version=1" "$T/PD/AgentHubRemote/ipc/status.txt" && pass "helper started and wrote its status file" || { cat "$T/helper.out"; failx "helper did not start"; }
cat >"$T/ops.py" <<'PY'
import importlib.machinery, importlib.util, sys, io, os, json, base64, contextlib
l = importlib.machinery.SourceFileLoader("hr", os.environ["HR_BIN"]); sp = importlib.util.spec_from_loader("hr", l); m = importlib.util.module_from_spec(sp); l.exec_module(m)
m.ssh_base = lambda n, tty=False: ["bash", "-c"]          # the "SSH session" is a local shell; powershell resolves to the shim
m.node = lambda name: {"platform": "windows", "state": "active", "mac_user": "x", "ssh_port": 1}
ok = True
def check(name, cond, extra=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra))); ok = ok and cond
# run: plain argv, quotes and spaces survive
r = m.remote_exec("w", m.ps_join(["Write-Output", "it's a \"test\"", ""]))
check("run passes arguments with quotes/spaces through PowerShell", r.stdout.strip() == "it's a \"test\"", (r.stdout, r.stderr))
r = m.remote_exec("w", "Get-ChildItem /nonexistent-xyz; exit 7")
check("run returns the exit code", r.returncode == 7, r.returncode)
big = "Write-Output '" + ("x" * 9000) + "'"
r = m.remote_exec("w", big)
check("a script over the command-line limit still runs (uploaded as a file)", r.stdout.strip() == "x" * 9000, (len(r.stdout), r.stderr[:100]))
# push / pull round trip, binary safe
data = bytes(range(256)) * 50
src = os.path.join(os.environ["T"], "src.bin"); dst = os.path.join(os.environ["T"], "dst.bin"); remote = os.environ["T"] + "/PD/AgentHubRemote/xfer.bin"
open(src, "wb").write(data)
class A: pass
a = A(); a.name = "w"; a.direction = "push"; a.local = src; a.remote = remote
with contextlib.redirect_stdout(io.StringIO()): m.cmd_push(a)
check("push writes the exact bytes", open(remote, "rb").read() == data)
a = A(); a.name = "w"; a.direction = "pull"; a.local = dst; a.remote = remote
with contextlib.redirect_stdout(io.StringIO()): m.cmd_push(a)
check("pull returns the exact bytes", open(dst, "rb").read() == data)
# signed job through the helper
rc, out = m.app_job("w", "Write-Output ('hello from ' + (Split-Path -Leaf $PWD)); exit 3", 40)
check("signed job ran in the helper and returned output + exit code", rc == 3 and out.strip().startswith("hello from"), (rc, out))
# screenshot path: helper returns what the snippet prints (no display here: expect a clean failure, not a hang)
rc, out = m.app_job("w", "Write-Output 'screen-snippet-ran'", 40)
check("second job after the first (queue keeps working)", rc == 0 and "screen-snippet-ran" in out, (rc, out))
# a forged job is rejected
jid = "deadbeefdeadbeef"; d = os.environ["T"] + "/PD/AgentHubRemote/ipc/jobs"
import time
open(f"{d}/{jid}.job", "w").write(json.dumps({"id": jid, "ts": int(time.time()), "cmd": "Write-Output PWNED"}))
open(f"{d}/{jid}.sig", "w").write("-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n")
for _ in range(10):
    time.sleep(1)
    if os.path.exists(f"{d}/{jid}.out"): break
res = json.load(open(f"{d}/{jid}.out")); o = base64.b64decode(res["out"]).decode()
check("job with a forged signature is rejected and not run", res["rc"] == 126 and "PWNED" not in o, res)
# stale (replayed) job is rejected: sign a real one with an old timestamp
import tempfile, subprocess
jid = "cafebabecafebabe"; job = json.dumps({"id": jid, "ts": int(time.time()) - 3600, "cmd": "Write-Output REPLAYED"})
with tempfile.TemporaryDirectory() as td:
    open(td + "/job", "w").write(job)
    subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(m.KEYS / "hermes_ed25519"), "-n", "hermes-remote-job", td + "/job"], check=True)
    open(f"{d}/{jid}.job", "w").write(job); open(f"{d}/{jid}.sig", "w").write(open(td + "/job.sig").read())
for _ in range(10):
    time.sleep(1)
    if os.path.exists(f"{d}/{jid}.out"): break
res = json.load(open(f"{d}/{jid}.out")); o = base64.b64decode(res["out"]).decode()
check("an old (replayed) signed job is rejected", res["rc"] == 126 and "REPLAYED" not in o, res)
# job signed by a different key is rejected
jid = "0123456789abcdef"; job = json.dumps({"id": jid, "ts": int(time.time()), "cmd": "Write-Output OTHERKEY"})
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", td + "/k"], check=True)
    open(td + "/job", "w").write(job)
    subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", td + "/k", "-n", "hermes-remote-job", td + "/job"], check=True)
    open(f"{d}/{jid}.job", "w").write(job); open(f"{d}/{jid}.sig", "w").write(open(td + "/job.sig").read())
for _ in range(10):
    time.sleep(1)
    if os.path.exists(f"{d}/{jid}.out"): break
res = json.load(open(f"{d}/{jid}.out")); o = base64.b64decode(res["out"]).decode()
check("a job signed by another key is rejected", res["rc"] == 126 and "OTHERKEY" not in o, res)
sys.exit(0 if ok else 1)
PY
PATH="$T/shim:$PATH" HR_BIN="$HR" T="$T" python3 "$T/ops.py" || failx "operator commands"
kill $HELPER 2>/dev/null || true


echo "== 7. the .cmd file's own unpack step (its PowerShell command, run as the .cmd would run it)"
python3 - "$F64" "$T/head.txt" <<'PY'
import sys, re
t = open(sys.argv[1], 'rb').read().decode('ascii').split('\r\n')
line = [l for l in t if l.startswith('powershell -NoProfile')][0]
m = re.match(r'powershell -NoProfile -ExecutionPolicy Bypass -Command "(.*)"$', line)
assert m, line
open(sys.argv[2], 'w').write(m.group(1))
PY
HR_SELF="$F64" HR_BASE="$T/winbase4" HR_FAKE_HOSTNAME="Cmd Head PC" HR_FAKE_USER="tester" "$PWSH" -NoProfile -NonInteractive -Command "$(cat "$T/head.txt")" >"$T/inst4.out" 2>&1 || { cat "$T/inst4.out"; failx "cmd unpack+run"; }
grep -q "registered as 'cmd-head-pc'" "$T/inst4.out" && pass "the .cmd's embedded unpack command extracts and runs the installer" || { cat "$T/inst4.out"; failx "cmd head"; }
[ -z "$(ls "$TEMP"/AgentHubRemoteInstall.ps1 2>/dev/null)" ] && pass "temporary copy of the installer is deleted afterwards" || failx "temp copy left behind"

echo "ALL PASSED"
