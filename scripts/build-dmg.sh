#!/bin/bash
# Builds a Release MacVoice.app and packages it as build/MacVoice.dmg
# with a drag-to-Applications layout. The app is signed with SIGN_IDENTITY
# (default: the local "Apple Development" certificate) and Hardened Runtime,
# so macOS keeps its permissions across updates. It is not notarized:
# Gatekeeper asks for confirmation the first time it opens on another Mac.
set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
ENTITLEMENTS="WinterVoice/Resources/WinterVoice.entitlements"

cd "$(dirname "$0")/.."

DERIVED_DATA="build/DerivedData-Release"
DMG_PATH="build/MacVoice.dmg"
VOLUME_NAME="MacVoice"

# Start from a clean products dir: an earlier scheme-based build embeds
# XCTest frameworks and the test bundle into the app, which must not ship.
rm -rf "$DERIVED_DATA/Build/Products"

# Build only the app target: the shared scheme also builds WinterVoiceTests,
# which cannot compile against a Release (non-testable) WinterVoice module.
xcodebuild \
  -project WinterVoice.xcodeproj \
  -target WinterVoice \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  SYMROOT="$PWD/$DERIVED_DATA/Build/Products" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/MacVoice.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle at $APP_PATH" >&2
  exit 1
fi

# Sign nested code first, then the app. Hardened Runtime denies microphone
# capture without the audio-input entitlement, so the app is signed with it.
# The app currently embeds no frameworks; the folder only exists when it does.
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) \
    | while IFS= read -r nested; do
        codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$nested"
      done
fi
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir "$STAGING_DIR/.background"
swift scripts/render-dmg-background.swift "$STAGING_DIR/.background/background.png"
cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
# Pre-seed .fseventsd with no_log so fseventsd writes no event store into the
# mounted image — without this an .fseventsd folder ships inside the DMG and
# shows up for anyone browsing with hidden files visible.
mkdir "$STAGING_DIR/.fseventsd"
touch "$STAGING_DIR/.fseventsd/no_log"

# Style the installer window on a writable image, then compress. Finder
# scripting stores the layout in the volume's .DS_Store; the first run on a
# machine prompts once for Automation permission over Finder.
RW_DMG="build/MacVoice-rw.dmg"
rm -f "$DMG_PATH" "$RW_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDRW \
  "$RW_DMG"

# A stale mounted volume makes the fresh image mount as "MacVoice 1"
# and the Finder styling hits the wrong disk — eject leftovers first, then
# take the mount point hdiutil actually reports.
MOUNT_POINT="/Volumes/$VOLUME_NAME"
if [[ -d "$MOUNT_POINT" ]]; then
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen \
  | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
if [[ "$MOUNT_POINT" != "/Volumes/$VOLUME_NAME" ]]; then
  echo "error: image mounted at '$MOUNT_POINT' instead of /Volumes/$VOLUME_NAME" >&2
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  exit 1
fi
SetFile -a C "$MOUNT_POINT" 2>/dev/null || true

osascript <<OSA
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    set position of item "MacVoice.app" of container window to {165, 192}
    set position of item "Applications" of container window to {495, 192}
    -- Park the helper entries far below the window so they stay out of
    -- sight even when the user browses with hidden files visible. Finder
    -- only lists them when hidden files are shown, hence the try blocks.
    try
      set position of item ".background" of container window to {165, 700}
    end try
    try
      set position of item ".fseventsd" of container window to {330, 700}
    end try
    try
      set position of item ".VolumeIcon.icns" of container window to {495, 700}
    end try
    update without registering applications
    delay 1
    -- Re-assert the bounds after the update so the final size is what
    -- Finder writes into .DS_Store on close.
    set the bounds of container window to {200, 120, 860, 548}
    delay 1
    close
  end tell
end tell
OSA

sync
# Mark the helper entries Finder-invisible on the volume itself, and drop
# any Finder/Spotlight droppings picked up while the image was mounted.
chflags hidden \
  "$MOUNT_POINT/.background" \
  "$MOUNT_POINT/.fseventsd" \
  "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
rm -rf "$MOUNT_POINT/.Trashes" "$MOUNT_POINT/.TemporaryItems" 2>/dev/null || true
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"

echo "Created $DMG_PATH"
