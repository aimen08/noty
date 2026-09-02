# Noty 原生本地化方案

## 目标

为 Noty 增加英文和简体中文界面，并继续由 macOS 根据系统语言或「按应用设置语言」自动选择显示语言。实现不得引入第三方 i18n 框架，也不得改变笔记数据、设置持久化值、URL Scheme 或导入导出格式的兼容性。

## 技术决策

运行时使用 SwiftUI 和 Foundation 自带的本地化能力：

- SwiftUI 静态文案继续使用 `Text("New Note")`、`Button("Archive")` 等接受 `LocalizedStringKey` 的初始化方法。
- AppKit 菜单、窗口标题、提示框、动态属性和传入普通 `String` 的文案使用 `String(localized:)`。
- 带数量变化的文案使用 `Localizable.stringsdict` 和 `String.localizedStringWithFormat`，由系统处理单复数规则。
- `RelativeDateTimeFormatter` 和 `DateFormatter` 继续跟随 `Locale.current`；仅翻译代码中手写的固定文案，例如 `just now`。

翻译资源采用传统的 `.lproj/Localizable.strings`，而不是在构建时编译 `Localizable.xcstrings`。两者都属于 Apple 原生方案，但当前项目通过 `swiftc` 和 shell 脚本直接组装应用。提交已编译可读取的 `.strings` 文件，可以继续满足「仅需 Command Line Tools，不要求完整 Xcode」的构建约束。

首批资源结构如下：

```text
Resources/
├── en.lproj/
│   ├── Localizable.strings
│   └── Localizable.stringsdict
└── zh-Hans.lproj/
    ├── Localizable.strings
    └── Localizable.stringsdict
```

英文原文作为本地化键。这样 SwiftUI 的静态字符串可以直接查表，现有源代码也不需要统一改成内部键名。翻译条目应带注释，说明出现位置或语境。

## 本地化范围

以下用户可见内容需要本地化：

- 应用主菜单、右键菜单及菜单层级。
- 设置窗口的标签页、控件名称、帮助文案、更新状态和快捷键录制提示。
- 全部笔记窗口、归档窗口、搜索框、空状态和详情操作。
- 笔记编辑器、快捷记录窗口、撤销删除提示、按钮帮助文本和方向选择器。
- 导入导出面板、完成提示、错误提示和数量文案。
- 默认笔记标题、颜色显示名称、尺寸显示名称、方向显示名称和牌组样式名称。
- 关于窗口和未包含 Sparkle 时的更新提示。

以下内容保持原值，不参与翻译：

- `noty://` URL Scheme、主机名和查询参数。
- `UserDefaults` 键、枚举 `rawValue`、显示器 ID 和数据库字段。
- `.stickies` 文件结构、JSON 键和用于兼容的内部值。
- Markdown 标记、快捷键符号、字体 PostScript 名称、文件扩展名和日志前缀。
- 用户输入的笔记标题、正文、文件名和系统提供的显示器名称。

颜色、尺寸和样式应将稳定值与显示名称分开。翻译只能影响 UI，不得把译文写入设置或归档文件。

## 构建集成

`build.sh` 在签名前将 `Resources/*.lproj` 递归复制到 `Noty.app/Contents/Resources/`。`Info.plist` 增加：

```xml
<key>CFBundleDevelopmentRegion</key>
<string>en</string>
```

应用包中应形成以下结构：

```text
Noty.app/Contents/Resources/en.lproj/Localizable.strings
Noty.app/Contents/Resources/zh-Hans.lproj/Localizable.strings
```

## 动态文案规则

不得通过拼接英文后缀实现单复数，例如：

```swift
"\(count) more note\(count == 1 ? \"\" : \"s\")"
```

应使用语义完整的格式键，例如 `more_notes_count`，并在 `Localizable.stringsdict` 中分别定义英文和简体中文规则。日期和时间组合也应把完整句子交给本地化系统，避免把中文硬套进英文语序。

SwiftUI 组件如果接收界面文案，应优先把参数类型声明为 `LocalizedStringKey`。必须生成 `String` 的 AppKit API 和模型属性再调用 `String(localized:)`。

## 验收标准

- 系统语言为英文时，现有英文界面保持完整且无本地化键泄漏。
- 系统语言为简体中文时，主菜单、右键菜单、设置、笔记库、编辑器、导入导出和更新提示显示中文。
- 数量为 `0`、`1`、`2` 时，英文单复数正确，中文句子自然。
- 相对时间和日期遵循当前系统区域设置。
- 切换语言不会修改现有笔记、快捷键、设置值或归档文件结构。
- `./build.sh debug` 和 `./scripts/test-editor.sh` 通过。
- 构建产物包含英文和简体中文 `.lproj` 资源，且 `plutil -lint` 检查所有 `.strings`、`.stringsdict` 文件通过。

## 暂不包含

- 应用内语言切换器。语言由 macOS 管理，切换后重新启动应用生效。
- README、网站和发布说明的翻译。
- 简体中文以外的新语言。后续可按相同目录结构添加。
