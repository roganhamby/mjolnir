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

# Set JAVA_HOME if not already pointing to a compatible JDK
if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME" ]; then
  if [ -d "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" ]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  elif [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  elif command -v /usr/libexec/java_home &> /dev/null; then
    JH="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    if [ -n "$JH" ]; then
      export JAVA_HOME="$JH"
    fi
  fi
fi

if [ -n "$JAVA_HOME" ]; then
  echo "Using JAVA_HOME: $JAVA_HOME"
fi

# Default to --debug if no arguments passed
BUILD_ARGS=("$@")
if [ ${#BUILD_ARGS[@]} -eq 0 ]; then
  BUILD_ARGS=("--debug")
fi

echo "Building Android APK with args: ${BUILD_ARGS[*]}..."
flutter build apk "${BUILD_ARGS[@]}"

echo ""
echo "=== Android Build Finished Successfully ==="
echo "Artifacts located in: build/app/outputs/flutter-apk/"
ls -la build/app/outputs/flutter-apk/ 2>/dev/null || true

# Copy newest build to ~/Downloads
NEWEST_APK="$(ls -t build/app/outputs/flutter-apk/*.apk 2>/dev/null | head -n 1)"
if [ -n "$NEWEST_APK" ] && [ -f "$NEWEST_APK" ]; then
  mkdir -p "$HOME/Downloads"
  cp -f "$NEWEST_APK" "$HOME/Downloads/"
  echo ""
  echo "Copied $(basename "$NEWEST_APK") to $HOME/Downloads/"
fi

