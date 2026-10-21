#!/usr/bin/env bash
set -e

# Change to the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Locate ADB
ADB_CMD=""
if command -v adb &> /dev/null; then
  ADB_CMD="adb"
elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
  ADB_CMD="$HOME/Library/Android/sdk/platform-tools/adb"
elif [ -n "$ANDROID_HOME" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
  ADB_CMD="$ANDROID_HOME/platform-tools/adb"
elif [ -n "$ANDROID_SDK_ROOT" ] && [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
  ADB_CMD="$ANDROID_SDK_ROOT/platform-tools/adb"
fi

if [ -z "$ADB_CMD" ]; then
  echo "Error: 'adb' command not found." >&2
  echo "Please install Android platform-tools or set ANDROID_HOME." >&2
  exit 1
fi

# 2. Check for APK file
APK_PATH="${1:-build/app/outputs/flutter-apk/app-debug.apk}"

if [ ! -f "$APK_PATH" ]; then
  echo "APK not found at: $APK_PATH"
  echo "Building debug APK now..."
  if [ -x "./build_android.sh" ]; then
    ./build_android.sh --debug
  else
    flutter build apk --debug
  fi
fi

if [ ! -f "$APK_PATH" ]; then
  echo "Error: Could not find or build APK at $APK_PATH" >&2
  exit 1
fi

echo "Target APK: $APK_PATH ($(du -h "$APK_PATH" | cut -f1))"

# 3. Check for connected Android device
echo "Checking for connected Android devices..."
DEVICES_OUTPUT="$("$ADB_CMD" devices | awk 'NR>1 && NF {print}')"

if [ -z "$DEVICES_OUTPUT" ]; then
  echo ""
  echo "⚠️  No Android device detected!"
  echo "Please check the following:"
  echo "  1. Connect your Android phone to this Mac using a USB cable."
  echo "  2. On your phone, go to Settings > Developer options > enable 'USB debugging'."
  echo "  3. Unlock your phone screen and look for an 'Allow USB debugging?' prompt."
  echo ""
  exit 1
fi

# Check for unauthorized devices
if echo "$DEVICES_OUTPUT" | grep -q "unauthorized"; then
  echo ""
  echo "⚠️  Device connected but unauthorized!"
  echo "Please unlock your phone and tap 'Allow' on the 'Allow USB debugging?' prompt."
  echo ""
  exit 1
fi

echo "Found connected device(s):"
echo "$DEVICES_OUTPUT"
echo ""

# 4. Install the APK
echo "Installing APK onto device..."
"$ADB_CMD" install -r -d "$APK_PATH"

echo ""
echo "=== Installation Successful! ==="

# 5. Optionally launch the app
read -r -p "Launch app now? [Y/n] " RESPONSE
RESPONSE="${RESPONSE:-Y}"
if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
  echo "Launching Mjolnir..."
  "$ADB_CMD" shell am start -n com.serversync.mjolnir/.MainActivity
fi
