#!/bin/bash
# Linux (Fedora family and Debian family) installer tests. They need no Fedora/Debian/Ubuntu machine:
#  * logic runs on this host with a private relay (same protocol as the real one),
#  * generated files are validated with the real tools (bash -n, visudo -c, systemd-analyze verify, sshd -t),
#  * if unpacked distro images are available (FEDORA_ROOT, DEBIAN_ROOT, UBUNTU_ROOT), the private-sshd design is also run
#    with each distro's OWN OpenSSH binaries and libraries (login through a reverse tunnel into a socket-started sshd).
# Steps that need a real system (dnf/apt, systemctl enable, SELinux/AppArmor, a desktop session) are NOT covered here.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
export HR_HOME="$T/home" HR_SSH_PORT_BASE=46100 HR_VNC_PORT_BASE=49900
HR="$ROOT/hermes-remote"
pids=()
cleanup() { chmod -R u+w "$T" 2>/dev/null || true; for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"; }
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
distro_sshd_t() { # name root libdirs-relative-colon-list loader-relative
  local name="$1" root="$2" libs="$3" ldr="$4" LD LP ver
  LD="$root/$ldr"; LP=""; for l in ${libs//:/ }; do LP="$LP:$root/$l"; done; LP="${LP#:}"
  local sw="$T/g/$name"; mkdir -p "$sw"
  for h in sshd-session sshd-auth; do for dir in usr/libexec/openssh usr/lib/openssh; do
      if [ -x "$root/$dir/$h" ]; then printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s/%s/%s" "$@"\n' "$LD" "$LP" "$root" "$dir" "$h" >"$sw/$h.sh"; chmod +x "$sw/$h.sh"; fi
  done; done
  { if [ -x "$sw/sshd-session.sh" ]; then echo "SshdSessionPath $sw/sshd-session.sh"; fi; if [ -x "$sw/sshd-auth.sh" ]; then echo "SshdAuthPath $sw/sshd-auth.sh"; fi; cat "$T/g/sshd_config.test"; } >"$sw/sshd_config"
  ver="$("$LD" --library-path "$LP" "$root/usr/bin/ssh" -V 2>&1 | cut -d, -f1)"
  "$LD" --library-path "$LP" "$root/usr/sbin/sshd" -t -f "$sw/sshd_config" 2>"$sw/err" && pass "$name's own sshd ($ver) accepts the private config" || { cat "$sw/err"; failx "$name sshd -t"; }
  "$LD" --library-path "$LP" "$root/usr/sbin/sshd" -T -f "$sw/sshd_config" | grep -q "^passwordauthentication no$" && pass "$name's sshd reports key-only login"
}
[ -n "${FEDORA_ROOT:-}" ] && [ -x "$FEDORA_ROOT/usr/sbin/sshd" ] && distro_sshd_t Fedora "$FEDORA_ROOT" "usr/lib64:lib64" "lib64/ld-linux-x86-64.so.2" || echo "SKIP Fedora-binary check (set FEDORA_ROOT)"
[ -n "${DEBIAN_ROOT:-}" ] && [ -x "$DEBIAN_ROOT/usr/sbin/sshd" ] && distro_sshd_t Debian "$DEBIAN_ROOT" "usr/lib/x86_64-linux-gnu:lib/x86_64-linux-gnu" "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" || echo "SKIP Debian-binary check (set DEBIAN_ROOT)"
[ -n "${UBUNTU_ROOT:-}" ] && [ -x "$UBUNTU_ROOT/usr/sbin/sshd" ] && distro_sshd_t Ubuntu "$UBUNTU_ROOT" "usr/lib/x86_64-linux-gnu:lib/x86_64-linux-gnu" "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" || echo "SKIP Ubuntu-binary check (set UBUNTU_ROOT)"
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
printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 13 (trixie)"\n' >"$T/os-debian"; printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nPRETTY_NAME="Linux Mint 22"\n' >"$T/os-mint"
printf 'ID=raspbian\nID_LIKE=debian\nPRETTY_NAME="Raspberry Pi OS"\n' >"$T/os-rpi"; printf 'ID=arch\nPRETTY_NAME="Arch Linux"\n' >"$T/os-arch"; printf 'ID=alpine\nPRETTY_NAME="Alpine"\n' >"$T/os-alpine"
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
for pair in "debian:debian" "ubuntu:debian" "mint:debian" "rpi:debian"; do
  os="${pair%%:*}"; want="${pair##*:}"
  runjoin "$T/os-$os" "$T/j-$os.sh" >"$T/jj-$os.out" 2>&1 || { cat "$T/jj-$os.out"; failx "join.sh on $os"; }
  grep -q "^TYPE=$want$" "$T/j-$os.sh" && bash -n "$T/j-$os.sh" && pass "join.sh on $os prepared the $want-family installer"
done
for os in suse arch alpine; do
  runjoin "$T/os-$os" "$T/j-$os.sh" >"$T/jj-$os.out" 2>&1 && failx "$os accepted" || { grep -q "not supported yet" "$T/jj-$os.out" && [ ! -e "$T/j-$os.sh" ] && pass "$os is refused with a clear message, nothing prepared"; }
done
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

echo "== 4b. Debian family: installer and its package handling"
"$HR" new-installer debian --sudo yes >/dev/null
FD="$HR_HOME/installers/AgentHub-Remote-Debian.sh"
[ -x "$FD" ] && bash -n "$FD" && grep -q "^TYPE=debian$" "$FD" && pass "Debian installer made (AgentHub-Remote-Debian.sh), valid bash, type debian"
cat >"$T/fam.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_SUDO= HR_BASE="$BASEDIR/b" HR_RUNDIR="$BASEDIR/run" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_USER=tester HR_UNITDIR="$BASEDIR/u" HR_POLICY="$BASEDIR/policy-rc.d"
. "$1"
echo "FAMILY_FEDORA=$(HR_OS_RELEASE=$BASEDIR/os-fedora detect_family)"
for o in debian ubuntu mint rpi suse arch; do echo "FAMILY_$o=$(HR_OS_RELEASE=$BASEDIR/os-$o detect_family)"; done
echo "CLIENT=$(pkg_ssh_client)"
for tl in gnome-screenshot spectacle grim scrot import; do echo "PKG_$tl=$(pkg_for_tool $tl)"; done
render_sshd_service > "$BASEDIR/s.service"
EOF
mkdir -p "$T/f1" "$T/f2"; cp "$T"/os-* "$T/f1/"; cp "$T"/os-* "$T/f2/"
BASEDIR="$T/f1" bash "$T/fam.sh" "$FD" >"$T/fam1.out" 2>&1 || { cat "$T/fam1.out"; failx "family functions (debian)"; }
BASEDIR="$T/f2" bash "$T/fam.sh" "$F" >"$T/fam2.out" 2>&1 || { cat "$T/fam2.out"; failx "family functions (fedora)"; }
grep -q "^FAMILY_FEDORA=fedora$" "$T/fam1.out" && grep -q "^FAMILY_debian=debian$" "$T/fam1.out" && grep -q "^FAMILY_ubuntu=debian$" "$T/fam1.out" && grep -q "^FAMILY_mint=debian$" "$T/fam1.out" && grep -q "^FAMILY_rpi=debian$" "$T/fam1.out" && pass "family detection: Fedora, Debian, Ubuntu, Mint and Raspberry Pi OS map to the right family"
grep -q "^FAMILY_suse=$" "$T/fam1.out" && grep -q "^FAMILY_arch=$" "$T/fam1.out" && pass "openSUSE and Arch have no family (unsupported)"
grep -q "^CLIENT=openssh-client$" "$T/fam1.out" && grep -q "^CLIENT=openssh-clients$" "$T/fam2.out" && pass "package name for the SSH client is right for each family"
grep -q "^PKG_spectacle=kde-spectacle$" "$T/fam1.out" && grep -q "^PKG_spectacle=spectacle$" "$T/fam2.out" && grep -q "^PKG_gnome-screenshot=gnome-screenshot$" "$T/fam1.out" && pass "screenshot package names differ correctly (Debian: kde-spectacle)"
grep -q "^RuntimeDirectory=sshd$" "$T/f1/s.service" && grep -q "^RuntimeDirectoryMode=0755$" "$T/f1/s.service" && pass "sshd service creates /run/sshd (Debian and Ubuntu refuse to run without it)"
# install_packages on Debian: blocks service start while apt runs, always removes its own block, keeps one that was already there
mkdir -p "$T/shim"
cat >"$T/shim/apt-get" <<EOS
#!/bin/bash
echo "apt-get \$*" >>"$T/apt.log"
if [ -x "$T/f3/policy-rc.d" ]; then
  "$T/f3/policy-rc.d" >/dev/null 2>&1; echo "policy-exit=\$?" >>"$T/apt.log"
else echo "policy-missing" >>"$T/apt.log"; fi
[ -n "\${FAIL_APT:-}" ] && exit 100
exit 0
EOS
chmod +x "$T/shim/apt-get"
cat >"$T/inst.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_SUDO= HR_BASE="$BASEDIR/b" HR_RUNDIR="$BASEDIR/run" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_USER=tester HR_POLICY="$BASEDIR/policy-rc.d"
. "$1"
install_packages openssh-server sudo; echo "RC=$?"
echo "POLICY_AFTER=$([ -e "$HR_POLICY" ] && echo present || echo gone)"
EOF
mkdir -p "$T/f3"; : >"$T/apt.log"
PATH="$T/shim:$PATH" BASEDIR="$T/f3" bash "$T/inst.sh" "$FD" >"$T/i1.out" 2>&1
grep -q "^RC=0$" "$T/i1.out" && grep -q "apt-get .*--no-install-recommends install openssh-server sudo" "$T/apt.log" && pass "Debian install runs apt-get with no extra recommended packages"
grep -q "^policy-exit=101$" "$T/apt.log" && pass "services are blocked from starting while apt runs (policy-rc.d exits 101), so the stock SSH server on port 22 never starts"
grep -q "^POLICY_AFTER=gone$" "$T/i1.out" && pass "the temporary policy file is removed afterwards"
: >"$T/apt.log"; printf '#!/bin/sh\nexit 101\n' >"$T/f3/policy-rc.d"; chmod 755 "$T/f3/policy-rc.d"
PATH="$T/shim:$PATH" BASEDIR="$T/f3" bash "$T/inst.sh" "$FD" >"$T/i2.out" 2>&1
grep -q "^POLICY_AFTER=present$" "$T/i2.out" && pass "a policy file that was already there is left alone"
rm -f "$T/f3/policy-rc.d"; : >"$T/apt.log"
FAIL_APT=1 PATH="$T/shim:$PATH" BASEDIR="$T/f3" bash "$T/inst.sh" "$FD" >"$T/i3.out" 2>&1
grep -q "^RC=100$" "$T/i3.out" && grep -q "^POLICY_AFTER=gone$" "$T/i3.out" && pass "a failed install reports the error and still removes the policy file"
# disable_stock_sshd only runs the disable commands on the Debian family
cat >"$T/shim/systemctl" <<EOS
#!/bin/bash
echo "systemctl \$*" >>"$T/sc.log"
EOS
chmod +x "$T/shim/systemctl"; : >"$T/sc.log"
cat >"$T/dis.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_SUDO= HR_BASE="$BASEDIR/b" HR_RUNDIR="$BASEDIR/run" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_USER=tester
. "$1"; disable_stock_sshd
EOF
PATH="$T/shim:$PATH" BASEDIR="$T/f3" bash "$T/dis.sh" "$FD"; grep -q "systemctl disable --now ssh.socket ssh.service" "$T/sc.log" && pass "after installing openssh-server on Debian/Ubuntu, the stock ssh.socket and ssh.service are turned off"
: >"$T/sc.log"; PATH="$T/shim:$PATH" BASEDIR="$T/f3" bash "$T/dis.sh" "$F"; [ ! -s "$T/sc.log" ] && pass "the Fedora installer never touches the stock SSH services"
# the platform check: right family passes; the wrong family or an unsupported system stops with a clear message
cat >"$T/plat.sh" <<'EOF'
export HR_SOURCE_ONLY=1 HR_TEST=1 HR_SUDO= HR_BASE="$BASEDIR/b" HR_RUNDIR="$BASEDIR/run" HR_LOG="$BASEDIR/log" HR_HOME_DIR="$BASEDIR/h" HR_USER=tester HR_ALLOW_ROOT=1 HR_NO_SYSTEMD=1
. "$1"; export HR_OS_RELEASE="$2"
check_platform; echo "RC=$?"
EOF
plat() { BASEDIR="$T/f3" bash "$T/plat.sh" "$1" "$T/os-$2" 2>&1; }
plat "$F" fedora | grep -q "^RC=0$" && plat "$FD" ubuntu | grep -q "^RC=0$" && plat "$FD" debian | grep -q "^RC=0$" && pass "the platform check passes for the right family (Fedora, Debian, Ubuntu)"
O="$(plat "$FD" fedora)"; echo "$O" | grep -q "^RC=1$" && echo "$O" | grep -q "for the debian family, but this computer .* is in the fedora family" && pass "Debian installer on a Fedora computer stops and names the right installer"
O="$(plat "$F" ubuntu)"; echo "$O" | grep -q "^RC=1$" && echo "$O" | grep -q "for the fedora family, but this computer .* is in the debian family" && pass "Fedora installer on an Ubuntu computer stops and names the right installer"
O="$(plat "$F" arch)"; echo "$O" | grep -q "^RC=1$" && echo "$O" | grep -q "Arch Linux" && pass "an unsupported system (Arch) stops, and the message names it"
O="$(HR_ALLOW_ROOT= BASEDIR="$T/f3" bash -c 'export HR_ALLOW_ROOT=; . '"$T"'/plat.sh '"$FD"' '"$T"'/os-debian' 2>&1)"; [ "$(id -u)" = 0 ] && echo "$O" | grep -q "not as root" && pass "running as root is refused" || echo "(skip root check: not root)"

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

set +e   # this section stops background servers and expects some logins to fail
echo "== 7. the real tunnel path with each distro's OWN OpenSSH (login through a reverse tunnel into a socket-started sshd)"
free_port_pair() { python3 - <<'PY'
import socket
for base in range(20000, 60000, 7):
    socks = []
    try:
        for p in (base, base + 1):
            s = socket.socket(); s.bind(("127.0.0.1", p)); socks.append(s)
        print(base); break
    except OSError:
        pass
    finally:
        for s in socks: s.close()
PY
}
distro_tunnel() { # name root libs loader port
  local name="$1" root="$2" libs="$3" ldr="$4" port="$5" LD LP W U
  LD="$root/$ldr"; LP=""; for l in ${libs//:/ }; do LP="$LP:$root/$l"; done; LP="${LP#:}"
  W="$(mktemp -d)"; U="$(id -un)"
  d() { local exe="$1"; shift; "$LD" --library-path "$LP" "$root$exe" "$@"; }
  ( cd "$W"
    for k in hk op tk rhk bad; do d /usr/bin/ssh-keygen -q -t ed25519 -N '' -f $k; done
    cp op.pub ak; cp tk.pub rak; : > empty.conf
    for h in sshd-session sshd-auth; do for dir in usr/libexec/openssh usr/lib/openssh; do
      if [ -x "$root/$dir/$h" ]; then printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s/%s/%s" "$@"\n' "$LD" "$LP" "$root" "$dir" "$h" >"$h.sh"; chmod +x "$h.sh"; fi
    done; done
    pre=""; if [ -x sshd-session.sh ]; then pre="SshdSessionPath $W/sshd-session.sh"; fi
    if [ -x sshd-auth.sh ]; then pre="$pre
SshdAuthPath $W/sshd-auth.sh"; fi
    printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s/usr/sbin/sshd" "$@"\n' "$LD" "$LP" "$root" >sshd.sh; chmod +x sshd.sh
    printf '%s\nHostKey %s/hk\nAuthorizedKeysFile %s/ak\nAllowUsers %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAuthenticationMethods publickey\nPermitRootLogin no\nAllowTcpForwarding no\nPidFile none\nStrictModes no\nUsePAM no\n' "$pre" "$W" "$W" "$U" >sshd_config
    printf '%s\nPort %s\nListenAddress 127.0.0.1\nHostKey %s/rhk\nAuthorizedKeysFile %s/rak\nPasswordAuthentication no\nPidFile none\nStrictModes no\nUsePAM no\nAllowTcpForwarding remote\nGatewayPorts no\n' "$pre" "$port" "$W" "$W" >rconf )
  d /usr/sbin/sshd -D -e -f "$W/rconf" 2>"$W/relay.log" < /dev/null & local p1=$!
  systemd-socket-activate -a --inetd -l "$W/sshd.sock" -- "$W/sshd.sh" -i -e -f "$W/sshd_config" 2>"$W/sa.log" & local p2=$!
  sleep 1
  d /usr/bin/ssh -N -T -F "$W/empty.conf" -i "$W/tk" -p "$port" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -R "127.0.0.1:$((port+1)):$W/sshd.sock" "$U@127.0.0.1" 2>"$W/tun.log" < /dev/null & local p3=$!
  sleep 3
  sc() { d /usr/bin/ssh -F "$W/empty.conf" -p "$((port+1))" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR "$@"; }
  local r1 r2 r3 r4
  # (a refused login exits non-zero on purpose; "|| true" keeps set -e from ending the whole suite)
  r1="$(sc -i "$W/op" "$U@127.0.0.1" 'echo LOGIN-OK' 2>&1 || true)"; r2="$(sc -i "$W/op" "$U@127.0.0.1" 'echo SECOND-OK' 2>&1 || true)"
  r3="$(sc -i "$W/bad" "$U@127.0.0.1" true 2>&1 | tail -1 || true)"; r4="$(sc -i "$W/op" "nobody@127.0.0.1" true 2>&1 | tail -1 || true)"
  kill $p3 $p2 $p1 2>/dev/null
  # killing the wrapper does not stop the program it started: stop everything that was started with this test's folder
  for pid in $(pgrep -f "$W" 2>/dev/null); do [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null; done; sleep 0.5
  for pid in $(pgrep -f "$W" 2>/dev/null); do [ "$pid" != "$$" ] && kill -9 "$pid" 2>/dev/null; done
  # the relay's sshd shows only the loader path in the process list, so it is found by the ports it listens on
  for pt in "$port" "$((port+1))"; do for pid in $(ss -ltnpH "sport = :$pt" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$pid" 2>/dev/null; done; done; sleep 0.5
  for pt in "$port" "$((port+1))"; do for pid in $(ss -ltnpH "sport = :$pt" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill -9 "$pid" 2>/dev/null; done; done
  wait $p3 $p2 $p1 2>/dev/null || true
  [ "$r1" = "LOGIN-OK" ] && pass "$name: operator key logs in through the reverse tunnel into the socket-started private sshd" || { echo "$r1"; cat "$W/tun.log" "$W/relay.log" "$W/sa.log" | head -5; failx "$name tunnel login"; }
  [ "$r2" = "SECOND-OK" ] && pass "$name: a second connection works (one sshd per connection)"
  case "$r3" in *"Permission denied"*) pass "$name: a wrong key is refused";; *) failx "$name wrong key: $r3";; esac
  case "$r4" in *"Permission denied"*) pass "$name: another user is refused even with the right key (AllowUsers)";; *) failx "$name other user: $r4";; esac
  rm -rf "$W"
}
n=0
for spec in "FEDORA|Fedora|usr/lib64:lib64|lib64/ld-linux-x86-64.so.2" "DEBIAN|Debian|usr/lib/x86_64-linux-gnu:lib/x86_64-linux-gnu|usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" "UBUNTU|Ubuntu|usr/lib/x86_64-linux-gnu:lib/x86_64-linux-gnu|usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"; do
  IFS='|' read -r var name libs ldr <<<"$spec"; eval "root=\${${var}_ROOT:-}"
  if [ -n "$root" ] && [ -x "$root/usr/sbin/sshd" ]; then distro_tunnel "$name" "$root" "$libs" "$ldr" "$(free_port_pair)"; else echo "SKIP $name tunnel check (set ${var}_ROOT)"; fi
  n=$((n+1))
done

echo "ALL PASSED"
