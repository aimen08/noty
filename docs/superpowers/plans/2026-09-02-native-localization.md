# Native Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用 macOS 原生本地化能力，为 Noty 增加完整的英文和简体中文界面。

**Architecture:** 使用 bundle 内的 `en.lproj` 和 `zh-Hans.lproj` 资源，由 SwiftUI、Foundation 和 AppKit 从 `Bundle.main` 读取翻译。静态 SwiftUI 文案沿用 `LocalizedStringKey`，普通 `String` 与 AppKit 文案显式调用 `String(localized:)`，数量变化使用 `.stringsdict`。

**Tech Stack:** Swift 5、SwiftUI、AppKit、Foundation、`Localizable.strings`、`Localizable.stringsdict`、shell。

**Spec:** `docs/i18n-native-localization-spec.md`

## Global Constraints

- 不引入第三方 i18n 框架。
- 最低系统版本保持 macOS 15.0。
- 构建继续由 `swiftc` 和 `build.sh` 完成，不要求完整 Xcode。
- `UserDefaults`、URL Scheme、数据库和 `.stickies` 格式中的稳定值不得翻译。
- 首批语言为英文 `en` 和简体中文 `zh-Hans`。

---

### Task 1: 建立资源和构建检查

**Files:**
- Create: `Resources/en.lproj/Localizable.strings`
- Create: `Resources/zh-Hans.lproj/Localizable.strings`
- Create: `Resources/en.lproj/Localizable.stringsdict`
- Create: `Resources/zh-Hans.lproj/Localizable.stringsdict`
- Create: `scripts/test-localization.sh`
- Modify: `Info.plist`
- Modify: `build.sh:45-51`

**Interfaces:**
- Consumes: `Bundle.main` 的系统语言选择行为。
- Produces: 构建产物中的 `en.lproj`、`zh-Hans.lproj` 和可重复运行的本地化资源检查脚本。

- [ ] **Step 1: 编写会失败的资源检查脚本**

创建 `scripts/test-localization.sh`，检查源资源、plist 语法、两种语言的键集合，以及构建产物内的资源：

```bash
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
import sys
from pathlib import Path

root = Path(sys.argv[1])
def keys(locale, name):
    with (root / "Resources" / f"{locale}.lproj" / name).open("rb") as f:
        return set(plistlib.load(f))

for name in ("Localizable.strings", "Localizable.stringsdict"):
    assert keys("en", name) == keys("zh-Hans", name), f"key mismatch in {name}"
PY

"$ROOT/build.sh" debug
for locale in en zh-Hans; do
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.strings"
    test -f "$APP/Contents/Resources/$locale.lproj/Localizable.stringsdict"
done
```

- [ ] **Step 2: 运行脚本并确认失败**

Run: `chmod +x scripts/test-localization.sh && ./scripts/test-localization.sh`

Expected: FAIL，因为本地化资源尚不存在或尚未复制到应用包。

- [ ] **Step 3: 添加基础资源和开发语言声明**

在两个 `Localizable.strings` 中先加入构建探针：

```text
/* Used by the localization bundle smoke test. */
"Noty" = "Noty";
```

简体中文文件同样保留产品名 `Noty`。创建两个合法的空字典格式 `Localizable.stringsdict`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

在 `Info.plist` 中加入：

```xml
<key>CFBundleDevelopmentRegion</key>
<string>en</string>
```

- [ ] **Step 4: 将本地化资源复制进应用包**

在 `build.sh` 复制图标之后加入：

```bash
for localization in "$ROOT"/Resources/*.lproj; do
    [ -d "$localization" ] && cp -R "$localization" "$APP/Contents/Resources/"
done
```

- [ ] **Step 5: 运行资源检查**

Run: `./scripts/test-localization.sh`

Expected: PASS，并在 `build/Noty.app/Contents/Resources/` 中找到两个 `.lproj` 目录。

- [ ] **Step 6: 提交资源骨架**

```bash
git add Info.plist build.sh scripts/test-localization.sh Resources/en.lproj Resources/zh-Hans.lproj
git commit -m "feat: add native localization resources"
```

### Task 2: 本地化 AppKit 菜单、窗口和提示框

**Files:**
- Modify: `Sources/AppDelegate.swift:145-217`
- Modify: `Sources/DeckController.swift:516-651`
- Modify: `Sources/SettingsWindow.swift:233-248`
- Modify: `Sources/LibraryWindow.swift:20-50`
- Modify: `Sources/Updater.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `Bundle.main` 中的 `Localizable.strings`。
- Produces: 本地化后的 `NSMenuItem.title`、`NSWindow.title`、`NSAlert` 和 Sparkle 缺失提示。

- [ ] **Step 1: 为 AppKit 字符串加入翻译条目**

为 `About Noty`、`Check for Updates…`、`New Note`、`All Notes`、`Archive`、`Settings…`、编辑菜单、右键菜单、关于窗口正文和更新错误提示建立英中对应条目。产品名、快捷键和技术名 `SQLite`、`AES-GCM`、`Sparkle` 保持不变。

- [ ] **Step 2: 显式本地化 AppKit 文案**

把 AppKit 初始化参数改为以下模式：

```swift
menu.addItem(
    withTitle: String(localized: "New Note"),
    action: #selector(newNote),
    keyEquivalent: "n"
)
```

窗口标题和提示框使用相同方式：

```swift
w.title = String(localized: "Noty Settings")
a.messageText = String(localized: "Updates are not available in this build")
```

用于再次查找菜单项的标题必须保存本地化后的值，不能再用英文数组调用 `item(withTitle:)`。可在创建 `NSMenuItem` 时直接保存引用并设置快捷键修饰符。

- [ ] **Step 3: 构建并检查 AppKit 改造**

Run: `./scripts/test-localization.sh`

Expected: PASS，编译器没有把 `String(localized:)` 与 AppKit API 的 `String` 参数混淆。

- [ ] **Step 4: 提交 AppKit 本地化**

```bash
git add Sources/AppDelegate.swift Sources/DeckController.swift Sources/SettingsWindow.swift Sources/LibraryWindow.swift Sources/Updater.swift Resources
git commit -m "feat: localize AppKit interface"
```

### Task 3: 本地化模型显示名称和设置界面

**Files:**
- Modify: `Sources/Core.swift:50-110,167-180,280,365-368`
- Modify: `Sources/DeckPanel.swift:7-16`
- Modify: `Sources/Settings.swift:45-47,147-149,161-166,238-240`
- Modify: `Sources/SettingsWindow.swift:1-510`
- Modify: `Sources/Shortcut.swift:14-44`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: 本地化资源和原有稳定枚举值、数值设置。
- Produces: 本地化的 `NoteColor.name`、`NoteTextDirection.title`、`DeckStyle.title`、尺寸名称、快捷键名称和设置界面。

- [ ] **Step 1: 将显示属性与稳定值分开**

保留 `DeckStyle.rawValue`、`NoteTextDirection.rawValue`、字体 PostScript 名称和设置索引不变。仅让显示属性返回本地化结果：

```swift
var title: String {
    switch self {
    case .tabs: String(localized: "Labelled tabs")
    case .compact: String(localized: "Colour chips")
    }
}
```

`Note.displayTitle` 和 `Fmt.ago` 使用同样方式处理 `New note` 与 `just now`。

- [ ] **Step 2: 本地化设置数据源中的名称**

将 `Settings.fontSizes`、`edgeWidths`、`noteSizes` 和 `deckSizes` 的 `name` 改为计算得到的本地化 `String`，数值、索引和持久化逻辑保持不变。例如：

```swift
static var fontSizes: [(name: String, size: Double)] {
    [
        (String(localized: "Small"), 12),
        (String(localized: "Medium"), 13.5),
        (String(localized: "Large"), 15.5),
        (String(localized: "Extra Large"), 18),
    ]
}
```

- [ ] **Step 3: 修复普通 String 参数造成的漏翻**

将只负责呈现文案的 SwiftUI helper 参数从 `String` 改为 `LocalizedStringKey`：

```swift
private func pane<Content: View>(
    _ caption: LocalizedStringKey,
    @ViewBuilder content: () -> Content
) -> some View

private func row<Content: View>(
    _ label: LocalizedStringKey,
    @ViewBuilder content: () -> Content
) -> some View
```

快捷键冲突检查继续接收内部标识 `new`、`archiveNote` 等，不对标识做本地化。

- [ ] **Step 4: 补齐设置与快捷键翻译**

加入设置四个标签页、所有控件、说明文字、快捷键名称、`Press keys…`、`Space`、`key %d` 和更新状态的英中条目。动态更新状态使用完整句子：

```swift
updateStatus = String(
    format: String(localized: "Last checked %@."),
    locale: .current,
    f.localizedString(for: last, relativeTo: Date())
)
```

- [ ] **Step 5: 构建和运行现有测试**

Run: `./scripts/test-localization.sh && ./scripts/test-editor.sh`

Expected: 两个脚本均 PASS。

- [ ] **Step 6: 提交设置与模型本地化**

```bash
git add Sources/Core.swift Sources/DeckPanel.swift Sources/Settings.swift Sources/SettingsWindow.swift Sources/Shortcut.swift Resources
git commit -m "feat: localize settings and display names"
```

### Task 4: 本地化笔记、资料库和导入导出流程

**Files:**
- Modify: `Sources/DeckViews.swift:560-770`
- Modify: `Sources/NoteEditor.swift:520-770`
- Modify: `Sources/LibraryWindow.swift:100-305`
- Modify: `Sources/QuickCapture.swift:95-140`
- Modify: `Sources/UndoToast.swift:55-80`
- Modify: `Sources/ExportImport.swift:47-225`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Resources/en.lproj/Localizable.stringsdict`
- Modify: `Resources/zh-Hans.lproj/Localizable.stringsdict`

**Interfaces:**
- Consumes: 本地化后的模型显示名称和 bundle 资源。
- Produces: 笔记操作、搜索、空状态、帮助文本和导入导出流程的完整英中界面。

- [ ] **Step 1: 本地化静态和条件 SwiftUI 文案**

静态字面量继续使用 `Text`、`Button`、`Label` 和 `TextField` 的本地化初始化方法。条件表达式会退化为普通 `String`，应分别本地化：

```swift
Text(model.query.isEmpty
    ? (model.mode == .all
        ? String(localized: "No notes yet")
        : String(localized: "Nothing archived"))
    : String(localized: "No matches"))
```

将 `footerButton(_ title: String, ...)` 改为接收 `LocalizedStringKey`。对 `.help(...)` 中的条件字符串显式调用 `String(localized:)`。

- [ ] **Step 2: 为数量文案增加复数资源**

为下列语义键分别加入英文复数规则和简体中文规则：

```text
more_notes_count
export_file_count
export_incomplete_count
import_added_count
notes_count
```

调用方式统一为：

```swift
let message = String.localizedStringWithFormat(
    NSLocalizedString("more_notes_count", comment: "Tooltip for hidden notes"),
    count
)
```

英文资源区分 `one` 和 `other`，简体中文资源使用 `other`。不要在 Swift 中追加 `s`。

- [ ] **Step 3: 本地化导入导出与错误信息**

本地化 `NSOpenPanel.prompt`、`message`、成功提示和失败提示。系统提供的 `error.localizedDescription`、文件名和扩展名原样作为格式参数插入译文。导出的 Markdown 正文属于用户数据格式；现有标题和元数据是否翻译以规格为准，首期保持原格式以避免同一归档随系统语言变化。

- [ ] **Step 4: 检查翻译键完整性**

Run: `./scripts/test-localization.sh`

Expected: PASS，英文和简体中文的 `.strings`、`.stringsdict` 键集合完全一致。

- [ ] **Step 5: 运行代码测试**

Run: `./scripts/test-editor.sh`

Expected: PASS，编辑器范围、样式和输入行为不受本地化改造影响。

- [ ] **Step 6: 提交主要界面本地化**

```bash
git add Sources/DeckViews.swift Sources/NoteEditor.swift Sources/LibraryWindow.swift Sources/QuickCapture.swift Sources/UndoToast.swift Sources/ExportImport.swift Resources
git commit -m "feat: localize note workflows"
```

### Task 5: 双语言人工验收和文档更新

**Files:**
- Modify: `README.md`
- Modify: `docs/i18n-native-localization-spec.md` only if implementation reveals a confirmed constraint

**Interfaces:**
- Consumes: 已完成的双语言应用包。
- Produces: 可复现的语言切换验证记录和更新后的构建说明。

- [ ] **Step 1: 验证英文界面**

Run:

```bash
./build.sh debug
build/Noty.app/Contents/MacOS/Noty -AppleLanguages '(en)'
```

Expected: 主菜单、右键菜单、设置、全部笔记、编辑器、快捷记录和导入导出均显示英文，不出现本地化键。

- [ ] **Step 2: 验证简体中文界面**

先退出上一实例，再运行：

```bash
build/Noty.app/Contents/MacOS/Noty -AppleLanguages '(zh-Hans)'
```

Expected: 同一组界面显示简体中文；快捷键、用户笔记、字体名、文件扩展名和产品名保持正确。

- [ ] **Step 3: 验证动态边界**

分别构造 `0`、`1`、`2` 条笔记和导入结果，检查隐藏笔记数量、导出提示和导入完成提示。切换英文与简体中文重复验证，并确认相对时间采用当前区域设置。

- [ ] **Step 4: 更新 README 构建说明**

在 Build 段补充：本地化资源位于 `Resources/*.lproj`，`build.sh` 会自动复制；新增语言时必须同时维护 `Localizable.strings` 和 `Localizable.stringsdict`，并运行 `./scripts/test-localization.sh`。

- [ ] **Step 5: 运行最终检查**

Run: `./scripts/test-localization.sh && ./scripts/test-editor.sh && git diff --check`

Expected: 全部 PASS，`git diff --check` 无输出。

- [ ] **Step 6: 提交验收文档**

```bash
git add README.md docs/i18n-native-localization-spec.md
git commit -m "docs: document native localization workflow"
```
