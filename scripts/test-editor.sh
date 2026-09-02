#!/bin/bash
# Focused range, Markdown, task, selection, and IME-defer checks for the native editor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/noty-editor-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

APP_SOURCES=()
for SOURCE_FILE in "$ROOT"/Sources/*.swift; do
    [ "$(basename "$SOURCE_FILE")" = "Main.swift" ] || APP_SOURCES+=("$SOURCE_FILE")
done

for ARCH in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 \
        -target "${ARCH}-apple-macosx15.0" \
        -sdk "$SDK" \
        "${APP_SOURCES[@]}" \
        "$ROOT/Tests/EditorStyleEngineTests.swift" \
        -o "$OUT/EditorStyleEngineTests-$ARCH"
done
lipo -create "$OUT/EditorStyleEngineTests-arm64" "$OUT/EditorStyleEngineTests-x86_64" \
    -output "$OUT/EditorStyleEngineTests"
lipo -info "$OUT/EditorStyleEngineTests" | grep -Eq 'arm64.*x86_64|x86_64.*arm64'

"$OUT/EditorStyleEngineTests"
