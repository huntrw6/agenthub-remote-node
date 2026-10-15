#!/bin/bash
# join.sh: set up this Mac for remote support.
#
#   curl -fsSL https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.sh | bash
#
# There is no code to type. At the end the Mac shows an approval code; read it to the person who
# sent you here. Nothing works until they approve that code. This script:
#   0. looks up the newest commit on main and uses ONLY that commit for every file below
#      (to use a fixed version instead, pass its raw URL as the first argument),
#   1. detects the Mac type (Intel or Apple silicon),
#   2. downloads the installer parts from <base> and checks them against MANIFEST.sha256,
#   3. fills in the public relay settings,
#   4. runs the guided installer.
# Nothing is installed until the guided installer asks you and you agree.
set -eu

REPO="${HR_REPO:-huntrw6/agenthub-remote-node}"
BASE="${1:-}"

die() { printf 'join: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this script is for macOS only."
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

case "$(uname -m)" in
  arm64) TYPE=silicon;;
  x86_64) TYPE=intel;;
  *) die "unsupported Mac type: $(uname -m)";;
esac

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/installer" "$W/config"

get() { curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 60 "$BASE/$1" -o "$W/$1" || die "could not download $1 (check the internet connection)"; }
for f in MANIFEST.sha256 installer/mac-installer.sh.tmpl installer/helper.js installer/launcher.js config/relay.env; do get "$f"; done

# every downloaded part must match the manifest, and every manifest entry must be present
# (the manifest also lists the Windows files, which a Mac does not download: check only the Mac files)
grep -E '  (installer/mac-installer\.sh\.tmpl|installer/helper\.js|installer/launcher\.js|config/relay\.env)$' "$W/MANIFEST.sha256" > "$W/MANIFEST.mac" || true
[ "$(wc -l < "$W/MANIFEST.mac" | tr -d ' ')" = 4 ] || die "MANIFEST.sha256 does not list all the Mac files; stopping."
( cd "$W" && shasum -a 256 -c MANIFEST.mac >/dev/null 2>&1 ) || die "downloaded files do not match MANIFEST.sha256; stopping."
for f in installer/mac-installer.sh.tmpl installer/helper.js installer/launcher.js config/relay.env; do
  grep -q "  $f\$" "$W/MANIFEST.sha256" || die "MANIFEST.sha256 does not list $f; stopping."
done

# shellcheck disable=SC1091
( set -a; . "$W/config/relay.env"; set +a; : "${RELAY_HOST:?}" "${RELAY_PORT:?}" "${RELAY_USER:?}" "${RELAY_HOSTKEY:?}" "${HERMES_PUB:?}" "${JOIN_KEY_B64:?}" ) || die "config/relay.env is incomplete."
set -a; . "$W/config/relay.env"; set +a

# fill the placeholders (perl ships with macOS); values are shell-quoted
export V_TYPE="$TYPE" V_OWNER="${OWNER:-the support person}" V_RELAY_HOST="$RELAY_HOST" V_RELAY_PORT="$RELAY_PORT" \
       V_RELAY_USER="$RELAY_USER" V_RELAY_HOSTKEY="$RELAY_HOSTKEY" V_HERMES_PUB="$HERMES_PUB" V_SUDO_MODE=yes \
       V_ENROLL_KEY_B64="$JOIN_KEY_B64" V_JOIN_MODE=1 V_DATE="$(date -u +%FT%TZ)" V_EXPIRES="the owner closes the setup window" \
       V_LAUNCHER_B64="$(base64 < "$W/installer/launcher.js" | tr -d '\n')" V_HELPER_B64="$(base64 < "$W/installer/helper.js" | tr -d '\n')"
perl -pe 's/\@\@([A-Z0-9_]+)\@\@/my $v = $ENV{"V_$1"}; die "no value for $1\n" unless defined $v; $v =~ s{\x27}{\x27\\\x27\x27}g; "\x27$v\x27"/ge' \
  "$W/installer/mac-installer.sh.tmpl" > "$W/run.command" || die "could not prepare the installer."
grep -q '@@' "$W/run.command" && die "installer still has unfilled placeholders."
bash -n "$W/run.command" || die "the prepared installer has a syntax error."
chmod 700 "$W/run.command"

# test hook: HR_JOIN_STOP_AT=<path> saves the prepared installer there and stops (it can only skip the install)
if [ -n "${HR_JOIN_STOP_AT:-}" ]; then cp "$W/run.command" "$HR_JOIN_STOP_AT"; exit 0; fi

echo "Prepared the $TYPE installer. Starting the guided setup."
# the guided installer reads answers from the keyboard (/dev/tty), not from this pipe
bash "$W/run.command" < /dev/tty
