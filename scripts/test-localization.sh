#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Noty.app"

for locale in en zh-Hans; do
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings"
    plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.stringsdict"
done

python3 - "$ROOT" <<'PY'
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])

deck_controller = (root / "Sources" / "DeckController.swift").read_text()
assert "String.LocalizationValue(title)" not in deck_controller, \
    "system display names must not be sent through localization lookup"
assert re.search(r"NSMenuItem\(title: title, action:", deck_controller), \
    "display menu must pass the composed title directly to NSMenuItem"
assert "String.LocalizationValue(s.title)" not in deck_controller, \
    "already localized deck style titles must not be looked up twice"
assert "String.LocalizationValue(f.name)" not in deck_controller, \
    "font display names must use the localized display property"

core = (root / "Sources" / "Core.swift").read_text()
deck_panel = (root / "Sources" / "DeckPanel.swift").read_text()
settings = (root / "Sources" / "Settings.swift").read_text()
settings_window = (root / "Sources" / "SettingsWindow.swift").read_text()
shortcut = (root / "Sources" / "Shortcut.swift").read_text()
assert "var displayName: String" in core, "palette and font faces need localized display properties"
assert 'String(localized: "New note")' in core, "empty note titles must use a localized fallback"
assert 'String(localized: "just now")' in core, "recent timestamps must localize just now"
assert 'String(localized: "Labelled tabs")' in deck_panel, "deck style titles must be localized"
assert 'static let fontSizes' in settings and 'static let edgeWidths' in settings, \
    "settings source values must remain stable constants"
assert 'private func pane(_ caption: LocalizedStringKey' in settings_window, \
    "settings pane captions must preserve localization keys"
assert 'private func row(_ label: LocalizedStringKey' in settings_window, \
    "settings row labels must preserve localization keys"
assert 'String(localized: "Press keys…")' in settings_window, \
    "shortcut recorder status must be localized"
assert 'String(format: String(localized: "Last checked %@.")' in settings_window, \
    "update status must format a localized complete sentence"
assert 'String(localized: "Space")' in shortcut, "space shortcut label must be localized"
assert 'String(localized: "key %d")' in shortcut, "unknown shortcut labels must be localized"

def keys(locale, name):
    source = root / "Resources" / f"{locale}.lproj" / name
    with tempfile.TemporaryDirectory() as directory:
        converted = Path(directory) / "converted.plist"
        subprocess.run(
            ["plutil", "-convert", "xml1", "-o", str(converted), str(source)],
            check=True,
        )
        with converted.open("rb") as f:
            return set(plistlib.load(f))

def values(locale, name):
    source = root / "Resources" / f"{locale}.lproj" / name
    with tempfile.TemporaryDirectory() as directory:
        converted = Path(directory) / "converted.plist"
        subprocess.run(
            ["plutil", "-convert", "xml1", "-o", str(converted), str(source)],
            check=True,
        )
        with converted.open("rb") as f:
            return plistlib.load(f)

for name in ("Localizable.strings", "Localizable.stringsdict"):
    assert keys("en", name) == keys("zh-Hans", name), f"key mismatch in {name}"

required_appkit = {
    "Noty": "Noty",
    "About Noty": "关于 Noty",
    "Check for Updates…": "检查更新…",
    "New Note": "新建笔记",
    "All Notes": "所有笔记",
    "Archive": "归档",
    "Settings…": "设置…",
    "Import…": "导入…",
    "Bigger Text": "放大文字",
    "Smaller Text": "缩小文字",
    "Hide Noty": "隐藏 Noty",
    "Quit Noty": "退出 Noty",
    "Edit": "编辑",
    "Undo": "撤销",
    "Redo": "重做",
    "Cut": "剪切",
    "Copy": "拷贝",
    "Paste": "粘贴",
    "Select All": "全选",
    "Show over full-screen apps": "在全屏 App 上显示",
    "Deck style": "牌组样式",
    "Labelled tabs": "带标签页",
    "Colour chips": "颜色块",
    "Note font": "笔记字体",
    "Text size": "文字大小",
    "Deck size": "牌组大小",
    "Keep deck open": "保持牌组展开",
    "Dock deck to left edge": "将牌组停靠在左侧边缘",
    "Display": "显示器",
    "All Displays": "所有显示器",
    "Main Display": "主显示器",
    "Main": "主",
    "Check automatically": "自动检查",
    "Launch at login": "登录时启动",
    "Export": "导出",
    "Markdown (one file per note)…": "Markdown（每篇笔记一个文件）…",
    "Plain text (one file per note)…": "纯文本（每篇笔记一个文件）…",
    "Single document…": "单个文档…",
    "Sticky archive (.stickies)…": "便笺归档（.stickies）…",
    "Noty Settings": "Noty 设置",
    "Sticky notes docked to the edge of your screen.\n\n⌥⌘N  new note      ⌥⌘A  all notes      ⌥⌘L  archive\nIn a note — Esc closes, ⌘F finds, ⌘. cycles colour, ⌘⌫ deletes.\n\nNotes are stored locally in an SQLite database; bodies are encrypted with AES-GCM. Your notes never leave this Mac — the only network request the app makes is the update check, which you can switch off.": "便笺停靠在屏幕边缘。\n\n⌥⌘N  新建笔记      ⌥⌘A  所有笔记      ⌥⌘L  归档\n在笔记中，Esc 关闭窗口，⌘F 查找，⌘. 切换颜色，⌘⌫ 删除。\n\n笔记保存在本机 SQLite 数据库中；正文使用 AES-GCM 加密。你的笔记不会离开这台 Mac，应用唯一的网络请求是检查更新，你可以将其关闭。",
    "Updates are not available in this build": "此版本无法检查更新",
    "This copy of Noty was built without the Sparkle framework. Run ./scripts/fetch-sparkle.sh and rebuild to enable automatic updates.": "此版本 Noty 构建时未包含 Sparkle 框架。运行 ./scripts/fetch-sparkle.sh 并重新构建，以启用自动更新。",
}
en = values("en", "Localizable.strings")
zh = values("zh-Hans", "Localizable.strings")
for key, expected_zh in required_appkit.items():
    assert key in en, f"missing AppKit key in en: {key}"
    assert key in zh, f"missing AppKit key in zh-Hans: {key}"
    assert en[key] == key, f"English AppKit value must preserve source text: {key}"
    assert zh[key] == expected_zh, f"unexpected zh-Hans AppKit value for {key!r}"

dynamic_menu_values = {
    "System": ("System", "系统"),
    "Noteworthy": ("Noteworthy", "Noteworthy"),
    "Bradley Hand": ("Bradley Hand", "Bradley Hand"),
    "Marker Felt": ("Marker Felt", "Marker Felt"),
    "Chalkboard": ("Chalkboard", "Chalkboard"),
    "Avenir Next": ("Avenir Next", "Avenir Next"),
    "New York": ("New York", "New York"),
    "Georgia": ("Georgia", "Georgia"),
    "Menlo": ("Menlo", "Menlo"),
    "Small": ("Small", "小"),
    "Medium": ("Medium", "中"),
    "Large": ("Large", "大"),
    "Extra Large": ("Extra Large", "超大"),
    "Default": ("Default", "默认"),
    "Extra large": ("Extra large", "特大"),
}
for key, (expected_en, expected_zh) in dynamic_menu_values.items():
    assert en[key] == expected_en, f"unexpected English dynamic menu value for {key!r}"
    assert zh[key] == expected_zh, f"unexpected zh-Hans dynamic menu value for {key!r}"

required_settings = {
    "Automatic": "自动",
    "Left to Right": "从左到右",
    "Right to Left": "从右到左",
    "Lemon": "柠檬",
    "Peach": "蜜桃",
    "Rose": "玫瑰",
    "Lilac": "丁香紫",
    "Sky": "天空蓝",
    "Mint": "薄荷绿",
    "Sand": "沙色",
    "Slate": "石板灰",
    "Huge": "超大",
    "Narrow": "窄",
    "Standard": "标准",
    "Wide": "宽",
    "Very wide": "很宽",
    "Shortcuts": "快捷键",
    "Deck": "牌组",
    "Notes": "笔记",
    "Updates": "更新",
    "Press keys…": "按下按键…",
    "Space": "空格",
    "key %d": "按键 %d",
    "Last checked %@.": "上次检查时间：%@。",
    "No check yet.": "尚未检查。",
    "This build has no Sparkle framework, so it cannot update itself.": "此版本没有 Sparkle 框架，无法自动更新。",
}
for key, expected_zh in required_settings.items():
    assert key in en, f"missing Task 3 key in en: {key}"
    assert key in zh, f"missing Task 3 key in zh-Hans: {key}"
    assert en[key] == key, f"English Task 3 value must preserve source text: {key}"
    assert zh[key] == expected_zh, f"unexpected zh-Hans Task 3 value for {key!r}"
PY

"$ROOT/build.sh" debug
for locale in en zh-Hans; do
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.stringsdict"
done
