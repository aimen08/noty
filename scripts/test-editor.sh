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

swiftc -parse-as-library -swift-version 5 \
    -target arm64-apple-macosx15.0 \
    -sdk "$SDK" \
    "${APP_SOURCES[@]}" \
    "$ROOT/Tests/LocalizationTests.swift" \
    "$ROOT/Tests/EditorStyleEngineTests.swift" \
    -o "$OUT/EditorStyleEngineTests"

"$OUT/EditorStyleEngineTests"
