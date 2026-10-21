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

# Default to --debug if no arguments passed
BUILD_ARGS=("$@")
if [ ${#BUILD_ARGS[@]} -eq 0 ]; then
  BUILD_ARGS=("--debug")
fi

echo "Building macOS application with args: ${BUILD_ARGS[*]}..."
flutter build macos "${BUILD_ARGS[@]}"

echo ""
echo "=== macOS Build Finished Successfully ==="
echo "Build outputs located in: build/macos/Build/Products/"
ls -la build/macos/Build/Products/ 2>/dev/null || true

# Copy newest build to ~/Downloads
NEWEST_APP="$(ls -td build/macos/Build/Products/*/*.app build/macos/Build/Products/*.app 2>/dev/null | head -n 1)"
if [ -n "$NEWEST_APP" ] && [ -d "$NEWEST_APP" ]; then
  APP_NAME="$(basename "$NEWEST_APP")"
  mkdir -p "$HOME/Downloads"
  rm -rf "$HOME/Downloads/$APP_NAME"
  cp -R "$NEWEST_APP" "$HOME/Downloads/"
  echo ""
  echo "Copied $APP_NAME to $HOME/Downloads/"
fi

