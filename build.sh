#!/bin/bash
# Builds Noty.app with the Swift command-line toolchain (no Xcode required).
#   ./build.sh          release build
#   ./build.sh debug    fast build, no optimisation
#   ./build.sh run      build then relaunch the app
#
# Set MARKETING_VERSION / BUILD_NUMBER to stamp the bundle (CI does this from the tag).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Noty.app"
BIN_DIR="$ROOT/build/.noty-bin"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
MODE="${1:-release}"

MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

OPT="-O"
[ "$MODE" = "debug" ] && OPT="-Onone"

rm -rf "$APP"
rm -rf "$BIN_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$BIN_DIR"
trap 'rm -rf "$BIN_DIR"' EXIT

# Sparkle is optional: with the framework present the app gets an updater,
# without it Updater.swift compiles to a stub that says so.
SPARKLE_FLAGS=()
if [ -d "$ROOT/Sparkle/Sparkle.framework" ]; then
    echo "→ linking Sparkle"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$ROOT/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
    SPARKLE_FLAGS=(-F "$ROOT/Sparkle" -framework Sparkle
                   -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
else
    echo "→ no Sparkle framework (run ./scripts/fetch-sparkle.sh to add updates)"
fi

echo "→ compiling ($MODE) $MARKETING_VERSION ($BUILD_NUMBER)"
# Releases ship one DMG per architecture — a universal binary cost a third of
# the download for a slice each Mac ignores. BUILD_ARCHS picks the slice(s);
# the default keeps local release builds universal, which is convenient for
# testing both, and debug builds stay native-only for speed.
ARCHES=(${BUILD_ARCHS:-arm64 x86_64})
[ "$MODE" = "debug" ] && ARCHES=("$(uname -m)")
for ARCH in "${ARCHES[@]}"; do
    echo "→ compiling $ARCH"
    swiftc $OPT -parse-as-library -swift-version 5 \
        -target "${ARCH}-apple-macosx15.0" \
        -sdk "$SDK" \
        "${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"}" \
        "$ROOT"/Sources/*.swift \
        -o "$BIN_DIR/Noty-$ARCH"
done
if [ "${#ARCHES[@]}" -gt 1 ]; then
    lipo -create "$BIN_DIR/Noty-arm64" "$BIN_DIR/Noty-x86_64" \
        -output "$APP/Contents/MacOS/Noty"
    lipo -info "$APP/Contents/MacOS/Noty" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'
else
    cp "$BIN_DIR/Noty-${ARCHES[0]}" "$APP/Contents/MacOS/Noty"
fi

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# Sparkle knows one feed. An Intel-only build must follow the Intel appcast, or
# its updates would hand it Apple Silicon disk images forever.
if [ "${#ARCHES[@]}" -eq 1 ] && [ "${ARCHES[0]}" = "x86_64" ]; then
    /usr/libexec/PlistBuddy -c \
        "Set :SUFeedURL https://raw.githubusercontent.com/aimen08/noty/main/appcast-intel.xml" \
        "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
for LOCALIZATION in "$ROOT"/Resources/*.lproj; do
    [ -d "$LOCALIZATION" ] && cp -R "$LOCALIZATION" "$APP/Contents/Resources/"
done
# Sparkle is MIT; redistributing its framework means shipping its notice too.
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
[ -f "$ROOT/licenses/THIRD-PARTY.txt" ] && cp "$ROOT/licenses/THIRD-PARTY.txt" "$APP/Contents/Resources/"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle ships signed by its own team and dyld refuses to load a framework whose
# Team ID differs from the process — so it has to be re-signed with our identity,
# innermost bundle first, before the app that embeds it.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_OPTS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_OPTS+=(--options runtime --timestamp)

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    V="$FW/Versions/B"
    for x in "$V"/XPCServices/*.xpc; do
        [ -e "$x" ] && codesign "${SIGN_OPTS[@]}" "$x"
    done
    [ -e "$V/Updater.app" ]  && codesign "${SIGN_OPTS[@]}" "$V/Updater.app"
    [ -e "$V/Autoupdate" ]   && codesign "${SIGN_OPTS[@]}" "$V/Autoupdate"
    codesign "${SIGN_OPTS[@]}" "$FW"
fi
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ signature valid"

echo "✓ built $APP"

if [ "$MODE" = "run" ] || [ "${2:-}" = "run" ]; then
    pkill -x Noty 2>/dev/null || true
    sleep 0.4
    open "$APP"
    echo "✓ launched"
fi
