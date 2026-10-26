#!/usr/bin/env bash
set -e

# Change to the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure Flutter is in PATH
if ! command -v flutter &> /dev/null; then
  if [ -x "$HOME/develop/flutter/bin/flutter" ]; then
    export PATH="$HOME/develop/flutter/bin:$PATH"
  else
    echo "Error: flutter command not found in PATH or ~/develop/flutter/bin." >&2
    exit 1
  fi
fi

# Default to --release if no arguments passed
BUILD_ARGS=("$@")
if [ ${#BUILD_ARGS[@]} -eq 0 ]; then
  BUILD_ARGS=("--release")
fi

echo "Building Linux application with args: ${BUILD_ARGS[*]}..."
flutter build linux "${BUILD_ARGS[@]}"

echo ""
echo "=== Linux Build Finished Successfully ==="
echo "Build outputs located in: build/linux/"
ls -la build/linux/*/*/bundle/ 2>/dev/null || true

# Package newest bundle and copy to ~/Downloads if available
NEWEST_BUNDLE="$(ls -td build/linux/*/*/bundle 2>/dev/null | head -n 1)"
if [ -n "$NEWEST_BUNDLE" ] && [ -d "$NEWEST_BUNDLE" ]; then
  mkdir -p "$HOME/Downloads"
  TAR_PATH="$HOME/Downloads/Mjolnir-Linux.tar.gz"
  tar -czf "$TAR_PATH" -C "$(dirname "$NEWEST_BUNDLE")" bundle
  echo ""
  echo "Packaged Linux bundle to $TAR_PATH"
fi
