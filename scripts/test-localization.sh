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
assert 'String(localized: "Main")' in settings_window, \
    "settings display marker must be localized independently"
assert '"\\(name) (Main)"' not in settings_window, \
    "settings display names must not embed an untranslated Main marker"
assert 'String(localized: "Press keys…")' in settings_window, \
    "shortcut recorder status must be localized"
assert 'String(format: String(localized: "Last checked %@.")' in settings_window, \
    "update status must format a localized complete sentence"
assert 'String(localized: "Space")' in shortcut, "space shortcut label must be localized"
assert 'String(localized: "key %d")' in shortcut, "unknown shortcut labels must be localized"
assert 'var exportTitle: String' in core, "exports need a stable title independent of UI locale"

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
    "Edge": "边缘",
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

# Task 4 note, library, capture, undo, and transfer workflows.
task4_sources = {
    "DeckViews.swift": (root / "Sources" / "DeckViews.swift").read_text(),
    "NoteEditor.swift": (root / "Sources" / "NoteEditor.swift").read_text(),
    "LibraryWindow.swift": (root / "Sources" / "LibraryWindow.swift").read_text(),
    "QuickCapture.swift": (root / "Sources" / "QuickCapture.swift").read_text(),
    "UndoToast.swift": (root / "Sources" / "UndoToast.swift").read_text(),
    "ExportImport.swift": (root / "Sources" / "ExportImport.swift").read_text(),
}
deck_views = task4_sources["DeckViews.swift"]
note_editor = task4_sources["NoteEditor.swift"]
library = task4_sources["LibraryWindow.swift"]
quick_capture = task4_sources["QuickCapture.swift"]
undo_toast = task4_sources["UndoToast.swift"]
transfer = task4_sources["ExportImport.swift"]

assert 'Text("Empty note")' in deck_views, "preview empty state must keep a localization key"
assert 'String.localizedStringWithFormat(\n            NSLocalizedString("more_notes_count"' in deck_views, \
    "overflow tooltip must use the plural resource"
assert '.help(c.displayName)' in note_editor, "editor color help must use the localized display name"
assert 'c.displayName' in library, "library color menu must use the localized display name"
assert 'c.displayName' in note_editor, "editor color controls must use the localized display name"
assert 'Button(idx == note.color ? "✓ \\(c.displayName)" : c.displayName)' in library, \
    "library color menu must use the localized display name"
assert 'private func footerButton(_ title: LocalizedStringKey' in note_editor, \
    "editor footer buttons must preserve localization keys"
assert 'String(localized: "No matches")' in library, "conditional library empty states must localize explicitly"
assert 'var displayTitle: String' in library and 'Text($0.displayTitle)' in library, \
    "library modes need a localized display title while raw values stay stable"
assert 'NSLocalizedString("export_file_count"' in transfer and 'String.localizedStringWithFormat' in transfer, \
    "export count copy must use the plural resource"
assert 'NSLocalizedString("import_added_count"' in transfer and 'String.localizedStringWithFormat' in transfer, \
    "import count copy must use the plural resource"
assert 'String(localized: "Quick note")' in quick_capture, "quick capture title must be localized explicitly"
assert 'Text("Note deleted")' in undo_toast, "undo copy must keep a localization key"
assert 'StickyNote' in transfer and 'colorName = n.palette.name' in transfer, \
    "archive colorName must remain the stable English persistence value"
assert not re.search(r"note\\\(count == 1 \?", transfer), "transfer code must not hand-build plural suffixes"
assert "n.exportTitle" in transfer, "Markdown export must use the stable export title"
assert "let raw = n.exportTitle" in transfer, "export filenames must use the stable export title"

# Every literal passed to a current UI/localization call site must be present in
# both locale tables. This intentionally derives the set from all source files,
# so removing a key from both locales still fails at its call site.
all_resource_keys = keys("en", "Localizable.strings") | keys("en", "Localizable.stringsdict")
ui_literal_patterns = (
    r'\b(?:Text|Button|Label|TextField)\(\s*"((?:\\.|[^"\\])*)"',
    r'\.help\(\s*"((?:\\.|[^"\\])*)"',
    r'String\(localized:\s*"((?:\\.|[^"\\])*)"',
    r'NSLocalizedString\(\s*"((?:\\.|[^"\\])*)"',
    r'\.(?:prompt|message)\s*=\s*"((?:\\.|[^"\\])*)"',
)
def decode_swift_literal(value):
    return value.replace("\\n", "\n").replace("\\\"", "\"").replace("\\\\", "\\")
source_literals = {}
for source_path in sorted((root / "Sources").glob("*.swift")):
    source_text = source_path.read_text()
    for pattern in ui_literal_patterns:
        for match in re.finditer(pattern, source_text, flags=re.DOTALL):
            raw = match.group(1)
            if "\\(" in raw:
                continue
            key = decode_swift_literal(raw)
            source_literals.setdefault(key, []).append(str(source_path))
missing_source_keys = sorted(set(source_literals) - all_resource_keys)
assert not missing_source_keys, f"UI literals missing from both locale resources: {missing_source_keys}"

info_path = root / "Info.plist"
with info_path.open("rb") as info_file:
    info = plistlib.load(info_file)
assert info.get("CFBundleDevelopmentRegion") == "en", "Info.plist development region must be en"

required_task4 = {
    "Empty note": "空笔记",
    "NEW NOTE": "新建笔记",
    "New Note  ⌥⌘N": "新建笔记  ⌥⌘N",
    "Settings  ⌘,": "设置  ⌘,",
    "Unpin": "取消置顶",
    "Pin": "置顶",
    "Archive": "归档",
    "Cycle colour  ⌘.": "切换颜色  ⌘.",
    "Delete": "删除",
    "Restore": "恢复",
    "Auto": "自动",
    "Text direction: %@": "文字方向：%@",
    "Unpin — ⌘P": "取消置顶 — ⌘P",
    "Pin so it stays open  ⌘P": "置顶以保持打开  ⌘P",
    "Task  ⌘T": "任务  ⌘T",
    "Find  ⌘F": "查找  ⌘F",
    "Find in note": "在笔记中查找",
    "Cycle colour · right-click to pick": "切换颜色 · 右键选择",
    "Select a note": "选择一篇笔记",
    "Search all notes": "搜索所有笔记",
    "No notes yet": "还没有笔记",
    "Nothing archived": "没有归档笔记",
    "No matches": "没有匹配项",
    "Markdown — one file per note…": "Markdown — 每篇笔记一个文件…",
    "Plain text — one file per note…": "纯文本 — 每篇笔记一个文件…",
    "Single document…": "单个文档…",
    "Sticky archive (.stickies)…": "便笺归档（.stickies）…",
    "Export Here": "在此导出",
    "Nothing to export": "没有可导出的内容",
    "There are no notes yet.": "还没有笔记。",
    "Export incomplete": "导出未完成",
    "See Console for details.": "详情请查看控制台。",
    "Edited %@": "编辑于 %@",
    "Saved · %@": "已保存 · %@",
    "Not saved": "未保存",
    "Export failed": "导出失败",
    "Choose a .stickies archive, or Markdown / text files.": "选择 .stickies 归档或 Markdown / 文本文件。",
    "Import complete": "导入完成",
    "Import finished with problems": "导入完成，但存在问题",
    "Could not read: %@": "无法读取：%@",
    "Quick note": "快速笔记",
    "↩ save    ⇧↩ new line    esc cancel": "↩ 保存    ⇧↩ 换行    esc 取消",
    "Note deleted": "笔记已删除",
    "Undo": "撤销",
}
for key, expected_zh in required_task4.items():
    assert key in en, f"missing Task 4 key in en: {key}"
    assert key in zh, f"missing Task 4 key in zh-Hans: {key}"
    assert en[key] == key, f"English Task 4 value must preserve source text: {key}"
    assert zh[key] == expected_zh, f"unexpected zh-Hans Task 4 value for {key!r}"

plural_expected = {
    "more_notes_count": ("%d more note", "%d more notes", "还有 %d 篇笔记"),
    "export_file_count": ("Choose a folder for %d %@ file.", "Choose a folder for %d %@ files.", "选择一个文件夹以保存 %d 个 %@ 文件。"),
    "export_incomplete_count": ("Wrote %2$d of %1$d note. See Console for details.", "Wrote %2$d of %1$d notes. See Console for details.", "已写入 %2$d/%1$d 篇笔记。详情请查看控制台。"),
    "import_added_count": ("Added %d note.", "Added %d notes.", "已添加 %d 篇笔记。"),
    "notes_count": ("%d note", "%d notes", "%d 篇笔记"),
}
en_dict = values("en", "Localizable.stringsdict")
zh_dict = values("zh-Hans", "Localizable.stringsdict")
for key, (en_one, en_other, zh_other) in plural_expected.items():
    assert key in en_dict and key in zh_dict, f"missing plural key: {key}"
    for locale, dictionary in (("en", en_dict), ("zh-Hans", zh_dict)):
        entry = dictionary[key]
        assert entry["NSStringLocalizedFormatKey"] == "%#@count@", f"bad plural format key: {locale}/{key}"
        count = entry["count"]
        assert count["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType", f"bad plural rule: {locale}/{key}"
        assert count["NSStringFormatValueTypeKey"] == "d", f"bad plural value type: {locale}/{key}"
    assert en_dict[key]["count"]["one"] == en_one, f"bad English one form: {key}"
    assert en_dict[key]["count"]["other"] == en_other, f"bad English other form: {key}"
    assert set(zh_dict[key]["count"]) == {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey", "other"}, \
        f"Chinese plural must use other only: {key}"
    assert zh_dict[key]["count"]["other"] == zh_other, f"bad Chinese other form: {key}"

# Exercise the count branches the same way the resources are consumed: English
# uses one for exactly 1 and other for 0/2; Chinese always uses other.
for count in (0, 1, 2):
    en_form = "one" if count == 1 else "other"
    for key in plural_expected:
        assert en_dict[key]["count"][en_form]
        assert zh_dict[key]["count"]["other"]
PY

"$ROOT/build.sh" debug
for locale in en zh-Hans; do
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.stringsdict"
done

# Exercise the real Foundation lookup/format path against both bundled locales.
# The source is temporary; only the compiled verifier runs after the app build.
RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/noty-localization.XXXXXX")"
trap 'rm -rf "$RUNTIME_DIR"' EXIT
RUNTIME_SOURCE="$RUNTIME_DIR/verify.swift"
cat > "$RUNTIME_SOURCE" <<'SWIFT'
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("expected app path") }
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    .appendingPathComponent("Contents/Resources", isDirectory: true)

func format(_ bundle: Bundle, _ key: String, _ arguments: [CVarArg]) -> String {
    let template = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    return withVaList(arguments) { NSString(format: template, arguments: $0) as String }
}

func check(_ locale: String, _ key: String, _ arguments: [CVarArg], _ expected: String) {
    guard let bundle = Bundle(path: resources.appendingPathComponent("\(locale).lproj").path) else {
        fatalError("could not load \(locale).lproj")
    }
    let actual = format(bundle, key, arguments)
    guard actual == expected else {
        fatalError("\(locale)/\(key): expected \(expected.debugDescription), got \(actual.debugDescription)")
    }
}

for count in [0, 1, 2] {
    let enNote = count == 1 ? "1 more note" : "\(count) more notes"
    let zhNote = "还有 \(count) 篇笔记"
    let enFiles = count == 1 ? "Choose a folder for 1 MD file." : "Choose a folder for \(count) MD files."
    let zhFiles = "选择一个文件夹以保存 \(count) 个 MD 文件。"
    let enAdded = count == 1 ? "Added 1 note." : "Added \(count) notes."
    let zhAdded = "已添加 \(count) 篇笔记。"
    let enCount = count == 1 ? "1 note" : "\(count) notes"
    let zhCount = "\(count) 篇笔记"
    let enIncomplete = "Wrote 0 of \(count) \(count == 1 ? "note" : "notes"). See Console for details."
    let zhIncomplete = "已写入 0/\(count) 篇笔记。详情请查看控制台。"

    check("en", "more_notes_count", [count], enNote)
    check("zh-Hans", "more_notes_count", [count], zhNote)
    check("en", "export_file_count", [count, "MD"], enFiles)
    check("zh-Hans", "export_file_count", [count, "MD"], zhFiles)
    check("en", "export_incomplete_count", [count, 0], enIncomplete)
    check("zh-Hans", "export_incomplete_count", [count, 0], zhIncomplete)
    check("en", "import_added_count", [count], enAdded)
    check("zh-Hans", "import_added_count", [count], zhAdded)
    check("en", "notes_count", [count], enCount)
    check("zh-Hans", "notes_count", [count], zhCount)
}
print("runtime plural checks passed for en and zh-Hans at counts 0, 1, 2")
SWIFT
swiftc "$RUNTIME_SOURCE" -o "$RUNTIME_DIR/verify"
"$RUNTIME_DIR/verify" "$APP"
