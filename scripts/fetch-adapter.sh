#!/usr/bin/env bash
# Downloads and builds ungive/mediaremote-adapter (BSD-3-Clause) into Vendor/MediaRemoteAdapter.
# It lets VYNL read macOS Now Playing (Spotify, SoundCloud in a browser, Apple Music, YouTube)
# since macOS 15.4 blocked apps from reading it directly.
# Needs git and cmake: brew install cmake
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer Xcode's toolchain when Xcode is installed: the standalone Command Line Tools can lag
# behind macOS, and pointing DEVELOPER_DIR here avoids needing sudo xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is missing. Install it with: brew install cmake"
  exit 1
fi

SRC="build/mediaremote-adapter-src"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" pull --ff-only
else
  mkdir -p build
  git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git "$SRC"
fi

# Configure from scratch every time: a failed attempt leaves cached compiler settings behind.
rm -rf "$SRC/build"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" --config Release

DEST="Vendor/MediaRemoteAdapter"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC/bin/mediaremote-adapter.pl" "$DEST/"
cp -R "$SRC/build/MediaRemoteAdapter.framework" "$DEST/"
cp "$SRC/LICENSE" "$DEST/" 2>/dev/null || true
git -C "$SRC" rev-parse HEAD > "$DEST/COMMIT"

echo "mediaremote-adapter $(cat "$DEST/COMMIT") is in $DEST"
echo "Quick check (prints what's playing, or null):"
/usr/bin/perl "$DEST/mediaremote-adapter.pl" "$(cd "$DEST" && pwd)/MediaRemoteAdapter.framework" get --no-artwork || true
