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
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
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
PY

"$ROOT/build.sh" debug
for locale in en zh-Hans; do
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.stringsdict"
done
