#!/bin/bash
# Packages build/Noty.app into a drag-to-Applications disk image.
#   ./scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Noty.app"
VERSION="${1:-${MARKETING_VERSION:-1.0.0}}"
DMG="$ROOT/build/Noty-${VERSION}.dmg"
RW_DMG="$ROOT/build/.Noty-${VERSION}-rw.dmg"

[ -d "$APP" ] || { echo "no app at $APP — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'hdiutil detach "$STAGE/Mount" -force >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW_DMG"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Create a writable image first so Finder can save the window layout in .DS_Store.
rm -f "$DMG" "$RW_DMG"
hdiutil create \
    -volname "Noty_${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDRW \
    -fs HFS+ \
    "$RW_DMG" >/dev/null

mkdir -p "$STAGE/Mount"
hdiutil attach "$RW_DMG" -nobrowse -noautoopen -mountpoint "$STAGE/Mount" >/dev/null
MOUNT="$STAGE/Mount"

mkdir -p "$MOUNT/.background"
if [ -f "$ROOT/Resources/DMGBackground.png" ]; then
    cp "$ROOT/Resources/DMGBackground.png" "$MOUNT/.background/background.png"
fi

# Configure the presentation as a native drag-to-Applications installer.
osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
    set volumePath to item 1 of argv
    tell application "Finder"
        set volumeFolder to POSIX file volumePath as alias
        open volumeFolder
        delay 1
        set volumeWindow to front window
        set toolbar visible of volumeWindow to false
        set statusbar visible of volumeWindow to false
        set bounds of volumeWindow to {350, 200, 750, 600}
        set current view of volumeWindow to icon view
        set iconOptions to the icon view options of volumeWindow
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 72
        set text size of iconOptions to 14
        set background picture of iconOptions to (POSIX file (volumePath & "/.background/background.png") as alias)
        set position of item "Noty.app" of volumeFolder to {95, 235}
        set position of item "Applications" of volumeFolder to {305, 235}
        try
            close volumeWindow
        end try
        delay 1
        try
            open volumeFolder
            delay 2
            close front window
        end try
    end tell
end run
APPLESCRIPT

hdiutil detach "$MOUNT" -force >/dev/null

# Compress the configured writable image for distribution.
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null

SIZE=$(stat -f%z "$DMG")
echo "✓ $DMG ($((SIZE / 1024 / 1024)) MB)"
