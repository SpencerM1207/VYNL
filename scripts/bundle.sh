#!/usr/bin/env bash
# Builds VYNL and wraps it into build/VYNL.app (the project folder is still called DevDock).
# Usage: scripts/bundle.sh [release|debug]
#
# Signing: uses your "Apple Development" certificate if one is in the keychain (free with a
# personal team: Xcode > Settings > Accounts > add your Apple ID > Manage Certificates > +).
# A stable signing identity keeps macOS permission grants (System Audio Recording, Automation)
# across rebuilds. Without one it signs ad hoc, and grants may reset on every rebuild.
# Override the identity with VYNL_SIGN_IDENTITY="Apple Development: Name (TEAMID)".
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer Xcode's toolchain when Xcode is installed: the standalone Command Line Tools can lag
# behind macOS, and pointing DEVELOPER_DIR here avoids needing sudo xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/VYNL.app"
rm -rf "$APP" build/DevDock.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/VYNL" "$APP/Contents/MacOS/VYNL"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# mediaremote-adapter: lets VYNL see every player, not just Spotify.
ADAPTER="Vendor/MediaRemoteAdapter"
HAS_ADAPTER=0
if [[ -f "$ADAPTER/mediaremote-adapter.pl" && -d "$ADAPTER/MediaRemoteAdapter.framework" ]]; then
  cp "$ADAPTER/mediaremote-adapter.pl" "$APP/Contents/Resources/"
  cp -R "$ADAPTER/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
  HAS_ADAPTER=1
else
  echo "Note: Vendor/MediaRemoteAdapter is missing, so VYNL will only see Spotify."
  echo "      Run scripts/fetch-adapter.sh to add SoundCloud, Apple Music, YouTube and the rest."
fi

IDENTITY="${VYNL_SIGN_IDENTITY:-${DEVDOCK_SIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ && !found { print $2; found = 1 }' || true)"
fi
SIGN_AS="${IDENTITY:--}"

# Source files from a downloaded zip or AirDrop carry quarantine flags, and cp/ditto copy them
# into the bundle. Clear every extended attribute so this stays a local build macOS won't flag
# (codesign also rejects some of them).
xattr -cr "$APP"

# Sign the nested framework first, then the app around it.
if [[ "$HAS_ADAPTER" == 1 ]]; then
  codesign --force --sign "$SIGN_AS" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
fi
codesign --force --sign "$SIGN_AS" "$APP"

if [[ -n "$IDENTITY" ]]; then
  echo "Signed with: $IDENTITY"
else
  echo "Signed ad hoc (no Apple Development certificate found). Permission grants may reset after rebuilds."
fi

# Install to ~/Applications so Spotlight, Launchpad and login items find one stable copy.
# Quit a running copy first (including the old DevDock) so the new build is the one that opens.
pkill -x VYNL 2>/dev/null && sleep 1 || true
pkill -x DevDock 2>/dev/null && sleep 1 || true
mkdir -p "$HOME/Applications"
# The app used to be called DevDock: move that copy to the Trash so there's only one.
if [[ -d "$HOME/Applications/DevDock.app" ]]; then
  mkdir -p "$HOME/.Trash"
  if mv "$HOME/Applications/DevDock.app" "$HOME/.Trash/DevDock-$(date +%s).app"; then
    echo "Moved the old ~/Applications/DevDock.app to the Trash."
  else
    echo "Couldn't move the old ~/Applications/DevDock.app to the Trash; delete it yourself."
  fi
fi
rm -rf "$HOME/Applications/VYNL.app"
ditto "$APP" "$HOME/Applications/VYNL.app"

echo "Built $APP and installed it to ~/Applications/VYNL.app."
echo "Run it with: open ~/Applications/VYNL.app"
