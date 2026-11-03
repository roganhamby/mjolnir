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

# Parse arguments: default to --release if --dmg is specified or if no arguments passed
MAKE_DMG=false
BUILD_ARGS=()

for arg in "$@"; do
  if [ "$arg" == "--dmg" ]; then
    MAKE_DMG=true
  else
    BUILD_ARGS+=("$arg")
  fi
done

if [ ${#BUILD_ARGS[@]} -eq 0 ]; then
  BUILD_ARGS=("--release")
  MAKE_DMG=true
fi

# If building release, enable DMG by default unless explicitly disabled
for arg in "${BUILD_ARGS[@]}"; do
  if [ "$arg" == "--release" ]; then
    MAKE_DMG=true
  fi
done

echo "Building macOS application with args: ${BUILD_ARGS[*]}..."
flutter build macos "${BUILD_ARGS[@]}"

echo ""
echo "=== macOS Build Finished Successfully ==="
echo "Build outputs located in: build/macos/Build/Products/"
ls -la build/macos/Build/Products/ 2>/dev/null || true

# Find newest .app bundle
NEWEST_APP="$(ls -td build/macos/Build/Products/*/*.app build/macos/Build/Products/*.app 2>/dev/null | head -n 1)"

if [ -n "$NEWEST_APP" ] && [ -d "$NEWEST_APP" ]; then
  APP_NAME="$(basename "$NEWEST_APP")"

  # Optional Code Signing if APPLE_SIGNING_IDENTITY is set
  if [ -n "$APPLE_SIGNING_IDENTITY" ]; then
    echo ""
    echo "Signing $APP_NAME with identity: $APPLE_SIGNING_IDENTITY..."
    codesign --force --deep --options runtime \
      --entitlements "macos/Runner/Release.entitlements" \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$NEWEST_APP"
  fi

  # Build DMG Installer if requested
  DMG_FILE=""
  if [ "$MAKE_DMG" = true ]; then
    DMG_FILE="${SCRIPT_DIR}/Mjolnir-Installer.dmg"
    rm -f "$DMG_FILE"

    echo ""
    echo "Creating macOS DMG installer..."

    if command -v create-dmg &> /dev/null; then
      VOLICON_ARGS=()
      if [ -f "$NEWEST_APP/Contents/Resources/AppIcon.icns" ]; then
        VOLICON_ARGS=(--volicon "$NEWEST_APP/Contents/Resources/AppIcon.icns")
      fi

      create-dmg \
        --volname "Mjolnir Installer" \
        "${VOLICON_ARGS[@]}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME" 150 190 \
        --hide-extension "$APP_NAME" \
        --app-drop-link 450 190 \
        --no-internet-enable \
        "$DMG_FILE" \
        "$NEWEST_APP" || [ $? -eq 2 ]

      echo "Created DMG: $DMG_FILE"

      # Sign DMG if identity provided
      if [ -n "$APPLE_SIGNING_IDENTITY" ]; then
        echo "Signing $DMG_FILE..."
        codesign --sign "$APPLE_SIGNING_IDENTITY" "$DMG_FILE"
      fi

      # Notarize if credentials provided
      if [ -n "$APPLE_NOTARY_PROFILE" ]; then
        echo "Submitting $DMG_FILE for notarization..."
        xcrun notarytool submit "$DMG_FILE" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_FILE"
      fi
    else
      echo "Notice: 'create-dmg' tool not found. Creating a standard disk image using hdiutil..."
      echo "Tip: Run 'brew install create-dmg' to enable styled drag-to-install DMGs."
      hdiutil create -volname "Mjolnir" -srcfolder "$NEWEST_APP" -ov -format UDZO "$DMG_FILE"
    fi
  fi

  # Copy to ~/Downloads if directory exists
  if [ -d "$HOME/Downloads" ]; then
    mkdir -p "$HOME/Downloads"
    rm -rf "$HOME/Downloads/$APP_NAME"
    cp -R "$NEWEST_APP" "$HOME/Downloads/"
    echo ""
    echo "Copied $APP_NAME to $HOME/Downloads/"

    if [ -n "$DMG_FILE" ] && [ -f "$DMG_FILE" ]; then
      cp -f "$DMG_FILE" "$HOME/Downloads/"
      echo "Copied $(basename "$DMG_FILE") to $HOME/Downloads/"
    fi
  fi
fi


