#!/bin/bash
# Builds NotchIsland.app.
#
#   ./build.sh            build, sign with a local certificate, install and launch (for your own Mac)
#   ./build.sh --release  build a shareable dist/NotchIsland.zip (ad-hoc signed, doesn't launch)
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[ "${1:-}" = "--release" ] && RELEASE=1

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install Apple's command line tools first:  xcode-select --install"
  exit 1
fi

echo "Building NotchIsland…"
swift build -c release

APP="build/NotchIsland.app"
RES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp ".build/release/NotchIsland" "$APP/Contents/MacOS/NotchIsland"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# ── Now Playing helper ────────────────────────────────────────────────────────
# Reads what Control Center shows. BSD-3 licensed, see Vendor/mediaremote-adapter.
echo "Building Now Playing helper…"
VENDOR="Vendor/mediaremote-adapter"
HELPER="build/adapter"
rm -rf "$HELPER"
mkdir -p "$HELPER/MediaRemoteAdapter.framework"
HELPER_OK=0
if clang -dynamiclib -O2 -fobjc-arc -fvisibility=default -w \
     -I"$VENDOR/include" -I"$VENDOR/src" \
     "$VENDOR"/src/adapter/*.m "$VENDOR"/src/private/*.m "$VENDOR"/src/utility/*.m \
     -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -framework MediaPlayer \
     -install_name "@rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter" \
     -o "$HELPER/MediaRemoteAdapter.framework/MediaRemoteAdapter"; then
  cp "$VENDOR/bin/mediaremote-adapter.pl" "$HELPER/mediaremote-adapter.pl"
  codesign --force --sign - "$HELPER/MediaRemoteAdapter.framework/MediaRemoteAdapter" >/dev/null 2>&1 || true
  cp -R "$HELPER" "$RES/adapter"          # ships inside the app
  HELPER_OK=1
else
  echo "⚠️  Now Playing helper failed to build — media falls back to Music/Spotify/browser scripts."
fi

# ── Release: shareable zip ────────────────────────────────────────────────────
if [ "$RELEASE" = "1" ]; then
  codesign --force --sign - "$APP"
  mkdir -p dist
  rm -f dist/NotchIsland.zip
  ditto -c -k --keepParent "$APP" dist/NotchIsland.zip
  echo "Release build ready: dist/NotchIsland.zip"
  exit 0
fi

# ── Local install ─────────────────────────────────────────────────────────────
if [ "$HELPER_OK" = "1" ]; then
  ADAPTER_DIR="$HOME/Library/Application Support/NotchIsland/adapter"
  rm -rf "$ADAPTER_DIR"
  mkdir -p "$(dirname "$ADAPTER_DIR")"
  cp -R "$HELPER" "$ADAPTER_DIR"
  echo "Now Playing check: $(/usr/bin/perl "$ADAPTER_DIR/mediaremote-adapter.pl" "$ADAPTER_DIR/MediaRemoteAdapter.framework" get --no-artwork 2>&1 | head -c 160)"
fi

# Sign with a permanent local certificate, so macOS remembers permissions (Accessibility) across rebuilds.
IDENTITY="NotchIsland Local Signing"
FRESH_IDENTITY=0
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Creating a local signing certificate (one time only)…"
  TMP="$(mktemp -d)"
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1 \
     && /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:notchisland -name "$IDENTITY" >/dev/null 2>&1 \
     && security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P notchisland -T /usr/bin/codesign >/dev/null 2>&1; then
    FRESH_IDENTITY=1
  else
    echo "⚠️  Couldn't create the certificate — using a temporary signature instead."
  fi
  rm -rf "$TMP"
fi

if codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
  echo "Signed with \"$IDENTITY\"."
  if [ "$FRESH_IDENTITY" = "1" ]; then
    tccutil reset Accessibility com.notchisland.app >/dev/null 2>&1 || true
  fi
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  tccutil reset Accessibility com.notchisland.app >/dev/null 2>&1 || true
  echo "⚠️  Used a temporary signature: you'll need to re-allow Accessibility after each build."
fi

pkill -x NotchIsland >/dev/null 2>&1 || true
sleep 0.3
open "$APP"
echo ""
echo "Done. NotchIsland is running — hover over your notch."
echo "For notifications and calls: allow NotchIsland in System Settings → Privacy & Security → Accessibility."
echo "(If a keychain window asks about \"codesign\", click Always Allow.)"
