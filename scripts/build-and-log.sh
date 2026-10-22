#!/usr/bin/env bash
# One command to build everything. The full output is saved to logs/build.log, where Claude
# can read it straight from this folder, so there's nothing to copy and paste.
# Usage (from Terminal): ~/Claude/claude_codes/DevDock/scripts/build-and-log.sh
cd "$(dirname "$0")/.."
# Prefer Xcode's toolchain when Xcode is installed: the standalone Command Line Tools can lag
# behind macOS, and pointing DEVELOPER_DIR here avoids needing sudo xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p logs
LOG="logs/build.log"

{
  echo "== $(date) =="
  sw_vers
  echo "xcode-select: $(xcode-select -p 2>&1)  DEVELOPER_DIR: ${DEVELOPER_DIR:-unset}"
  swift --version 2>&1

  if [[ ! -d Vendor/MediaRemoteAdapter ]]; then
    echo
    echo "== fetch-adapter =="
    scripts/fetch-adapter.sh || echo "fetch-adapter failed; building without it (Spotify only)."
  fi

  echo
  echo "== bundle =="
  scripts/bundle.sh release
  echo "== bundle exit code: $? =="
} 2>&1 | tee "$LOG"

echo
echo "Saved to $(pwd)/$LOG. Tell Claude it's done."
