#!/usr/bin/env bash
# salted.TV setup — installs the bridge to ~/.cache/salted.TV and verifies tools.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Never write inside the plugin dir — omarchy watches it with inotifywait -r
# and any write triggers a full shell plugin reload (screen blink).
RUNTIME="${XDG_CACHE_HOME:-$HOME/.cache}/salted.TV"
BRIDGE_SRC="$DIR/bridge/salted-tv-bridge.py"
BRIDGE_DST="$RUNTIME/salted-tv-bridge.py"
VERSION="$(jq -er '.version' "$DIR/manifest.json" 2>/dev/null || echo "0.1.0")"
VERSION_FILE="$RUNTIME/version"

say()  { printf '\033[1;36m[salted.TV]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[salted.TV]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[salted.TV]\033[0m %s\n' "$*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v mpv >/dev/null 2>&1 || warn "mpv not found — install with: omarchy pkg add mpv"

mkdir -p "$RUNTIME"

if [[ -x "$BRIDGE_DST" && -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" == "$VERSION" ]]; then
  say "bridge $VERSION already installed"
  exit 0
fi

say "installing bridge $VERSION → $BRIDGE_DST"
install -Dm0755 "$BRIDGE_SRC" "$BRIDGE_DST"

say "checking SDR toolchain ..."
have_soapy=false; have_rx=false; have_tv=false
if command -v SoapySDRUtil >/dev/null 2>&1; then
  have_soapy=true
  say "SoapySDRUtil found"
else
  warn "SoapySDRUtil missing — install with: omarchy pkg add soapysdr"
fi
if command -v rx_fm >/dev/null 2>&1 && command -v rx_power >/dev/null 2>&1; then
  have_rx=true
  say "rx-tools found (rx_fm / rx_sdr / rx_power)"
else
  warn "rx-tools missing (FM + scan disabled) — install from AUR: paru -S rx-tools"
fi
if command -v leandvb >/dev/null 2>&1; then
  have_tv=true
  say "leandvb found (DVB-T enabled)"
else
  warn "leandvb missing (DVB-T TV disabled) — optional: paru -S leandvb"
fi

say "probing SDR devices ..."
if $have_soapy && SoapySDRUtil --find= 2>/dev/null | grep -q 'driver='; then
  say "SDR device(s) detected:"
  SoapySDRUtil --find= 2>/dev/null | grep 'driver=' | sed 's/^/  /'
else
  warn "no SDR device detected — plug one in and restart the shell"
fi

say "verifying bridge ..."
if ! python3 "$BRIDGE_DST" '{"cmd":"ping"}' 2>/dev/null | grep -q '"ok": *true'; then
  warn "bridge ping failed — check python3"
else
  say "bridge ping OK"
fi

printf '%s\n' "$VERSION" > "$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"

say "installed $BRIDGE_DST ($VERSION) — ready"
echo "SALTEDTV_RESTART_SHELL=1"

exit 0
