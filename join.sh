#!/bin/bash
# join.sh: set up this Mac or Linux computer for remote support.
#
#   curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
#
# There is no code to type. At the end the computer shows an approval code; read it to the person who
# sent you here. Nothing works until they approve that code. This script:
#   0. looks up the newest commit on main and uses ONLY that commit for every file below
#      (to use a fixed version instead, pass its raw URL as the first argument),
#   1. detects the computer type (Intel or Apple silicon Mac; Fedora-family Linux),
#   2. downloads the installer parts from <base> and checks them against MANIFEST.sha256,
#   3. fills in the public relay settings,
#   4. runs the guided installer.
# Nothing is installed until the guided installer asks you and you agree.
set -eu

REPO="${HR_REPO:-huntrw6/agenthub-remote-node}"
BASE="${1:-}"

die() { printf 'join: %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
case "$OS" in
  Darwin) ;;
  Linux) ;;
  *) die "this script is for macOS and Linux. For Windows, use join.ps1.";;
esac
if [ -z "$BASE" ]; then
  SHA="$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$REPO/commits/main")" || die "could not look up the newest version (check the internet connection)"
  case "$SHA" in *[!0-9a-f]*|"") die "unexpected answer while looking up the newest version.";; esac
  [ "${#SHA}" -eq 40 ] || die "unexpected answer while looking up the newest version."
  BASE="https://raw.githubusercontent.com/$REPO/$SHA"
fi
case "$BASE" in
  https://raw.githubusercontent.com/*/*/????????????????????????????????????????) ;;
  *) die "usage: curl -fsSL <base>/join.sh | bash -s -- <base>  (a raw.githubusercontent.com address pinned to a 40-character commit)";;
esac
case "$BASE" in *[!A-Za-z0-9/._:-]*) die "the base URL has unexpected characters.";; esac

if [ "$OS" = Darwin ]; then
  case "$(uname -m)" in
    arm64) TYPE=silicon;;
    x86_64) TYPE=intel;;
    *) die "unsupported Mac type: $(uname -m)";;
  esac
else
  # which Linux family? (only the Fedora family is supported so far)
  ID=""; ID_LIKE=""
  # shellcheck disable=SC1091
  OSR="${HR_OS_RELEASE:-/etc/os-release}"   # (the override is for tests)
  [ -r "$OSR" ] && . "$OSR"
  case " ${ID:-} ${ID_LIKE:-} " in
    *" fedora "*|*" rhel "*|*" centos "*) TYPE=fedora;;
    *) die "this Linux (${PRETTY_NAME:-unknown}) is not supported yet. Supported: Fedora, RHEL, Rocky Linux, AlmaLinux, CentOS Stream.";;
  esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "unsupported processor: $(uname -m)";; esac
fi

# sha256 check that works on both macOS (shasum) and Linux (sha256sum)
sha_check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1"; else shasum -a 256 -c "$1"; fi; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/installer" "$W/config"

get() { curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 60 "$BASE/$1" -o "$W/$1" || die "could not download $1 (check the internet connection)"; }
if [ "$OS" = Darwin ]; then
  FILES="installer/mac-installer.sh.tmpl installer/helper.js installer/launcher.js config/relay.env"
else
  FILES="installer/linux-installer.sh.tmpl installer/linux-helper.sh config/relay.env"
fi
for f in MANIFEST.sha256 $FILES; do get "$f"; done

# every downloaded part must be listed in the manifest and match it
# (the manifest also lists the files of other systems, which are not downloaded: check only ours)
: > "$W/MANIFEST.mine"
for f in $FILES; do
  grep -E "^[0-9a-f]{64}  $(printf '%s' "$f" | sed 's/[.]/\\./g')\$" "$W/MANIFEST.sha256" >> "$W/MANIFEST.mine" || die "MANIFEST.sha256 does not list $f; stopping."
done
[ "$(wc -l < "$W/MANIFEST.mine" | tr -d ' ')" = "$(printf '%s\n' $FILES | wc -l | tr -d ' ')" ] || die "MANIFEST.sha256 does not list all the files; stopping."
( cd "$W" && sha_check MANIFEST.mine >/dev/null 2>&1 ) || die "downloaded files do not match MANIFEST.sha256; stopping."

# shellcheck disable=SC1091
( set -a; . "$W/config/relay.env"; set +a; : "${RELAY_HOST:?}" "${RELAY_PORT:?}" "${RELAY_USER:?}" "${RELAY_HOSTKEY:?}" "${HERMES_PUB:?}" "${JOIN_KEY_B64:?}" ) || die "config/relay.env is incomplete."
set -a; . "$W/config/relay.env"; set +a

if [ "$OS" = Darwin ]; then
  # fill the placeholders (perl ships with macOS); values are shell-quoted
  export V_TYPE="$TYPE" V_OWNER="${OWNER:-the support person}" V_RELAY_HOST="$RELAY_HOST" V_RELAY_PORT="$RELAY_PORT" \
         V_RELAY_USER="$RELAY_USER" V_RELAY_HOSTKEY="$RELAY_HOSTKEY" V_HERMES_PUB="$HERMES_PUB" V_SUDO_MODE=yes \
         V_ENROLL_KEY_B64="$JOIN_KEY_B64" V_JOIN_MODE=1 V_DATE="$(date -u +%FT%TZ)" V_EXPIRES="the owner closes the setup window" \
         V_LAUNCHER_B64="$(base64 < "$W/installer/launcher.js" | tr -d '\n')" V_HELPER_B64="$(base64 < "$W/installer/helper.js" | tr -d '\n')"
  perl -pe 's/\@\@([A-Z0-9_]+)\@\@/my $v = $ENV{"V_$1"}; die "no value for $1\n" unless defined $v; $v =~ s{\x27}{\x27\\\x27\x27}g; "\x27$v\x27"/ge' \
    "$W/installer/mac-installer.sh.tmpl" > "$W/run.command" || die "could not prepare the installer."
  grep -q '@@' "$W/run.command" && die "installer still has unfilled placeholders."
  RUN="$W/run.command"
else
  # Linux: the template has one settings marker; replace it with the quoted settings block
  { printf 'TYPE=%q\nOWNER=%q\nGENERATED=%q\nEXPIRES=%q\nRELAY_HOST=%q\nRELAY_PORT=%q\nRELAY_USER=%q\nRELAY_HOSTKEY=%q\nHERMES_PUB=%q\nSUDO_MODE=%q\nJOIN_MODE=%q\nENROLL_KEY_B64=%q\nHELPER_B64=%q\n' \
      "$TYPE" "${OWNER:-the support person}" "$(date -u +%FT%TZ)" "the owner closes the setup window" "$RELAY_HOST" "$RELAY_PORT" "$RELAY_USER" "$RELAY_HOSTKEY" \
      "$HERMES_PUB" yes 1 "$JOIN_KEY_B64" "$(base64 < "$W/installer/linux-helper.sh" | tr -d '\n')" > "$W/settings.txt"
    while IFS= read -r line; do
      if [ "$line" = '#@@CONFIG@@' ]; then cat "$W/settings.txt"; else printf '%s\n' "$line"; fi
    done < "$W/installer/linux-installer.sh.tmpl"
  } > "$W/run.sh" || die "could not prepare the installer."
  [ "$(grep -c '^#@@CONFIG@@$' "$W/installer/linux-installer.sh.tmpl")" = 1 ] || die "installer template is malformed."
  RUN="$W/run.sh"
fi
bash -n "$RUN" || die "the prepared installer has a syntax error."
chmod 700 "$RUN"
cp "$RUN" "$W/run.prepared"

# test hook: HR_JOIN_STOP_AT=<path> saves the prepared installer there and stops (it can only skip the install)
if [ -n "${HR_JOIN_STOP_AT:-}" ]; then cp "$RUN" "$HR_JOIN_STOP_AT"; exit 0; fi

echo "Prepared the $TYPE installer. Starting the guided setup."
# the guided installer reads answers from the keyboard (/dev/tty), not from this pipe
bash "$RUN" < /dev/tty
