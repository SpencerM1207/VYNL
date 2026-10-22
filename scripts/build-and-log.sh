#!/usr/bin/env bash
# One command to build everything. The full output is saved to logs/build.log, where Claude
# can read it straight from this folder, so there's nothing to copy and paste.
# Usage (from Terminal, in this folder): scripts/build-and-log.sh
cd "$(dirname "$0")/.."
# Prefer Xcode's toolchain when Xcode is installed: the standalone Command Line Tools can lag
# behind macOS, and pointing DEVELOPER_DIR here avoids needing sudo xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p logs
LOG="logs/build.log"
STATUS="logs/.status"
echo 1 > "$STATUS"

{
  echo "== $(date) =="
  sw_vers
  echo "xcode-select: $(xcode-select -p 2>&1)  DEVELOPER_DIR: ${DEVELOPER_DIR:-unset}"
  swift --version 2>&1

  # A half-updated Command Line Tools install crashes Swift before it builds anything
  # ("Symbol not found ... swift-package", exit 134). Say so plainly instead.
  if ! swift package --version >/dev/null 2>&1; then
    echo
    echo "Your Mac's developer tools aren't working: Swift crashes before it can build."
    echo "Fix it one of these ways, then run this script again:"
    echo "  1. Reinstall the Command Line Tools (about 10 minutes):"
    echo "       sudo rm -rf /Library/Developer/CommandLineTools"
    echo "       xcode-select --install"
    echo "  2. Or install Xcode from the App Store and open it once. This script uses it automatically."
    exit 1
  fi

  if [[ ! -d Vendor/MediaRemoteAdapter ]]; then
    echo
    echo "== fetch-adapter =="
    scripts/fetch-adapter.sh || echo "fetch-adapter failed; building without it (Spotify only)."
  fi

  echo
  echo "== bundle =="
  scripts/bundle.sh release
  status=$?
  echo "== bundle exit code: $status =="
  echo "$status" > "$STATUS"
} 2>&1 | tee "$LOG"

echo
if [[ "$(cat "$STATUS" 2>/dev/null)" == 0 ]]; then
  echo "Done. Open it with: open ~/Applications/VYNL.app"
else
  echo "The build didn't finish. Everything it printed is saved in $(pwd)/$LOG."
fi
