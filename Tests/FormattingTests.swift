import AppKit
import SwiftUI

enum FormattingTests {
    static func run(check: (Bool, String) -> Void) {
        let original = "项目：整理👩🏽‍💻便签，今天完成\n下一段"
        let selected = (original as NSString).range(of: "整理👩🏽‍💻便签")
        guard let bold = NoteFormatting.edit(original, selection: selected, command: .bold),
              let underline = NoteFormatting.edit(bold.text, selection: bold.selection, command: .underline),
              let strike = NoteFormatting.edit(underline.text, selection: underline.selection, command: .strike),
              let sized = NoteFormatting.edit(strike.text, selection: strike.selection, command: .size(24)) else {
            check(false, "formatting selected Chinese/emoji text must produce an edit"); return
        }
        check(NoteFormatting.plainText(sized.text) == original, "formatting must preserve all visible Unicode content")
        check(NoteFormatting.selectedText(sized.text, range: sized.selection) == "整理👩🏽‍💻便签",
              "formatting must preserve the logical selection across UTF-16 emoji")
        let runs = NoteFormatting.runs(in: sized.text)
        check(runs.count == 1 && runs[0].style.bold && runs[0].style.underline && runs[0].style.strike
              && runs[0].style.size == 24, "bold, underline, strike and size must compose without nested wrappers")
        let part = (sized.text as NSString).range(of: "整理")
        let partial = NoteFormatting.edit(sized.text, selection: part, command: .bold)!
        let split = NoteFormatting.runs(in: partial.text)
        check(split.count == 2 && !split[0].style.bold && split[1].style.bold
              && split.allSatisfy { $0.style.size == 24 && $0.style.underline },
              "toggling bold on part of a styled run must preserve its other styles and neighbors")
        let plain = NoteFormatting.edit(sized.text, selection: sized.selection, command: .clear)!
        check(plain.text == original && plain.selection == selected, "clear formatting must restore text and selection")

        let paragraph = NoteFormatting.edit("前一段\n这一段\n后一段", selection: NSRange(location: 6, length: 0), command: .italic)!
        let paragraphRun = NoteFormatting.runs(in: paragraph.text).first!
        check((paragraph.text as NSString).substring(with: paragraphRun.content) == "这一段",
              "without a selection only the current paragraph should change")

        let across = NSRange(location: (partial.text as NSString).range(of: "理").location,
                             length: (partial.text as NSString).range(of: "便签").upperBound
                                - (partial.text as NSString).range(of: "理").location)
        let replaced = NoteFormatting.replacing(partial.text, range: across, with: "理好")!
        check(NoteFormatting.plainText(replaced.text) == "项目：整理好，今天完成\n下一段",
              "editing across formatting boundaries must not leak markup or erase neighbors")

        let tasks = "☐ 第一项\n☑ 第二项\n# 标题\n![image](noty-img://sample)"
        let formattedTasks = NoteFormatting.edit(tasks, selection: NSRange(location: 0, length: tasks.utf16.count), command: .underline)!
        check(formattedTasks.text.hasPrefix("☐ ") && formattedTasks.text.contains("\n☑ ")
              && formattedTasks.text.contains("\n# "), "task and heading prefixes must stay editable outside formatting")
        check(ImageStore.tokens(in: formattedTasks.text).count == 1, "formatting must preserve image token syntax")
        let unformattedTasks = NoteFormatting.edit(formattedTasks.text,
            selection: NSRange(location: 0, length: formattedTasks.text.utf16.count), command: .underline)
        check(unformattedTasks?.text == tasks, "toggling a formatted list off must ignore its protected checkbox prefixes")
        var note = Note()
        note.body = sized.text
        check(note.displayTitle == "项目：整理👩🏽‍💻便签，今天完成", "derived titles must not show formatting markup")
        note.title = "便签"
        check(!note.preview.contains("<span") && NoteQuery(text: "项目：整理👩🏽‍💻便签").results(in: [note]).count == 1,
              "previews and searches must use contiguous visible text")
        check(NoteFormatting.markdown(sized.text).contains("font-size:24px")
              && !NoteFormatting.markdown(sized.text).contains("data-noty-style"),
              "Markdown exports must use portable inline HTML formatting")
        do {
            let archive = StickyArchive(notes: [StickyNote(note)])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let restored = try Transfer.decodeArchive(encoder.encode(archive))
            check(restored.first?.body == sized.text, "backup/import must retain the full formatting payload")
        } catch { check(false, "formatted backup round trip failed: \(error)") }

        let tv = makeTextView(sized.text)
        for markdown in [true, false] {
            style(tv, markdown: markdown)
            let storage = tv.textStorage!
            let body = runs[0].content
            let font = storage.attribute(.font, at: body.location, effectiveRange: nil) as! NSFont
            check(font.pointSize == 24 && NSFontManager.shared.traits(of: font).contains(.boldFontMask),
                  "explicit font size and bold must render with Markdown on or off")
            check(storage.attribute(.underlineStyle, at: body.location, effectiveRange: nil) as? Int == 1
                  && storage.attribute(.strikethroughStyle, at: body.location, effectiveRange: nil) as? Int == 1,
                  "underline and strikethrough must render")
            check(runs[0].markers.allSatisfy { storage.attribute(.notyHidden, at: $0.location, effectiveRange: nil) != nil },
                  "explicit formatting syntax must stay hidden on the active editing line")
            check(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil,
                  "styles must not bleed into adjacent text")
        }
        let marker = runs[0].markers[0]
        check(tv.selectionOutsideFormattingMarkers(NSRange(location: marker.location + 1, length: 0),
                                                   from: NSRange(location: marker.location, length: 0)).location == marker.upperBound,
              "cursor navigation must skip hidden formatting syntax")
        testEditingAndUndo(check: check)
        testInputPanelClicks(check: check)
        testHoverPreview(check: check)
        testFormattingKeepsViewport(check: check)
        testFormattedNewlines(check: check)
    }

    private static func testFormattedNewlines(check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        for original in ["字号加粗🙂", "☐ 字号加粗🙂", "- 字号加粗🙂", "1. 字号加粗🙂"] {
            var saved = original
            let tv = makeTextView(saved)
            let bridge = EditorBridge(); bridge.textView = tv
            let wrapper = NoteTextView(text: Binding(get: { saved }, set: { saved = $0 }), ink: .textColor,
                                       bridge: bridge, autofocus: false, fontSize: 14)
            let coordinator = wrapper.makeCoordinator()
            tv.delegate = coordinator; coordinator.attach(to: tv)
            tv.setSelectedRange(NSRange(location: 0, length: tv.string.utf16.count))
            bridge.format(.size(24)); bridge.format(.bold)
            let run = NoteFormatting.runs(in: tv.string).last!
            tv.setSelectedRange(NSRange(location: NSMaxRange(run.content), length: 0))
            tv.insertNewline(nil)
            let visible = NoteFormatting.plainText(tv.string)
            let prefix = original.hasPrefix("☐") ? "☐ " : original.hasPrefix("- ") ? "- " : original.hasPrefix("1.") ? "2. " : ""
            let expected = original + "\n" + prefix
            check(visible == expected, "Return must retain the text and produce exactly one continuation: \(visible.debugDescription)")
            check(visible.filter { $0 == "\n" }.count == 1,
                  "Return after sized bold text must insert one newline (\(original)): \(tv.string.debugDescription)")
            check(NoteFormatting.runs(in: tv.string).allSatisfy {
                !(tv.string as NSString).substring(with: $0.content).contains("\n")
            }, "Return must keep hidden style boundaries out of the new paragraph: \(tv.string.debugDescription)")
            tv.insertText("下一行", replacementRange: tv.selectedRange())
            check(NoteFormatting.plainText(tv.string) == expected + "下一行" && saved == tv.string,
                  "typing after Return must not leave an extra blank line and must autosave")
            if !prefix.isEmpty {
                tv.insertNewline(nil)
                tv.insertNewline(nil)
                check(NoteFormatting.plainText(tv.string) == expected + "下一行\n",
                      "Return on an empty continued list item must exit without adding another blank line")
            }
            tv.delegate = nil; tv.textStorage?.delegate = nil
        }
    }

    private static func testFormattingKeepsViewport(check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let original = (1...120).map { "第\($0)段：长便签的内容，调整样式以后仍然留在这里。🙂" }.joined(separator: "\n")
        var saved = original
        let tv = makeTextView(original)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 15, height: 6)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let bridge = EditorBridge(); bridge.textView = tv
        let wrapper = NoteTextView(text: Binding(get: { saved }, set: { saved = $0 }), ink: .textColor,
                                   bridge: bridge, autofocus: false, fontSize: 14, styleToken: "viewport-14")
        let coordinator = wrapper.makeCoordinator()
        tv.delegate = coordinator; coordinator.attach(to: tv)
        coordinator.parent.styleToken = "viewport-initial"
        coordinator.synchronize(tv)
        window.makeFirstResponder(tv)
        func settleLayout() {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            tv.sizeToFit()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        defer {
            tv.delegate = nil; tv.textStorage?.delegate = nil
            tv.undoManager?.removeAllActions()
            window.close()
        }
        settleLayout()
        let selected = (tv.string as NSString).range(of: "第100段：长便签的内容")
        tv.setSelectedRange(selected)
        tv.scrollRangeToVisible(selected)
        settleLayout()
        let selectedGlyph = tv.layoutManager!.glyphIndexForCharacter(at: selected.location)
        let selectedY = tv.layoutManager!.lineFragmentRect(forGlyphAt: selectedGlyph, effectiveRange: nil).minY
            + tv.textContainerOrigin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: selectedY + 3))
        scroll.reflectScrolledClipView(scroll.contentView)
        let startingY = scroll.contentView.bounds.minY
        check(startingY > 1000, "viewport regression must start well below the top of a long note")
        for command: NoteFormatting.Command in [.size(24), .bold, .underline, .strike, .size(12), .clear] {
            bridge.format(command)
            coordinator.synchronize(tv)
            settleLayout()
            check(abs(scroll.contentView.bounds.minY - startingY) < 50,
                  "formatting at the bottom must keep the viewport instead of returning to the top (\(command): \(startingY) -> \(scroll.contentView.bounds.minY))")
            check(NoteFormatting.selectedText(tv.string, range: tv.selectedRange()) == "第100段：长便签的内容",
                  "formatting must retain the selected passage in the scrolled editor")
            check(saved == tv.string && NoteFormatting.plainText(saved) == original,
                  "preserving the viewport must not interfere with autosave or visible text")
        }
        func passageY() -> CGFloat {
            let range = (tv.string as NSString).range(of: "第100段")
            let layout = tv.layoutManager!
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                + tv.textContainerOrigin.y - scroll.contentView.bounds.minY
        }
        let passageBefore = passageY()
        tv.setSelectedRange(NSRange(location: 0, length: tv.string.utf16.count))
        bridge.format(.size(28))
        settleLayout()
        check(abs(passageY() - passageBefore) < 50,
              "resizing all text must keep the same visible passage, not just the old pixel scroll offset (\(passageBefore) -> \(passageY()))")
        bridge.format(.clear)
        settleLayout()
        check(abs(passageY() - passageBefore) < 50,
              "clearing whole-note formatting must also preserve the visible passage")
        // Scrolling does not move the insertion point. Restyling must preserve
        // what is being read even when the old caret is above the viewport.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: startingY))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.makeFirstResponder(nil)
        bridge.format(.size(28))
        settleLayout()
        check(scroll.contentView.bounds.minY > 1000,
              "formatting after scrolling with an offscreen caret must not jump back to the caret at the top")
        let beforeBaseFont = passageY()
        coordinator.parent.fontSize = 20
        coordinator.parent.styleToken = "viewport-20"
        coordinator.synchronize(tv)
        settleLayout()
        check(abs(passageY() - beforeBaseFont) < 50,
              "changing the note's base font must keep the same visible passage")
    }

    private static func testHoverPreview(check: (Bool, String) -> Void) {
        let original = "整理计划\n加粗内容👩🏽‍💻\n☐ 待办事项\n☑ 已完成\n下划线和字号\n第五行不在悬停卡片内"
        var formatted = original
        for command: NoteFormatting.Command in [.bold, .italic, .underline, .strike, .size(24)] {
            formatted = NoteFormatting.edit(formatted,
                selection: NSRange(location: 0, length: formatted.utf16.count), command: command)!.text
        }
        var note = Note(body: formatted)
        check(note.displayTitle == "整理计划", "hover title must hide explicit formatting markers")
        check(Array(note.previewLines.prefix(4)) == ["加粗内容👩🏽‍💻", "☐ 待办事项", "☑ 已完成", "下划线和字号"],
              "hover preview must hide all style markers before limiting lines, while keeping Unicode and task state")
        check(note.taskProgress?.done == 1 && note.taskProgress?.total == 2,
              "formatted hover previews must retain checklist progress")
        check(note.body == formatted && NoteFormatting.runs(in: note.body).count > 0,
              "rendering a plain preview must leave stored formatting intact")

        note.title = "独立标题"
        check(note.previewLines.first == "整理计划", "custom-title hover cards must retain the first content line")
        check(note.preview == note.previewLines.joined(separator: " "),
              "hover and list previews must use the same visible content")

        let legacy = Note(body: "<span data-noty-style=\"b,u,z24\">标题\n跨行样式🙂\n☐ 待办</span>")
        check(legacy.previewLines == ["跨行样式🙂", "☐ 待办"],
              "legacy multiline style spans must be decoded before splitting preview lines")
        let images = Note(body: "![image](noty-img://sample)\n<span data-noty-style=\"b\"> </span>\n<span data-noty-style=\"u\">标题</span>\n<span data-noty-style=\"i\">正文</span>")
        check(images.displayTitle == "标题" && images.previewLines == ["正文"],
              "styled blank lines and image-only lines must not offset the title/body split")
        let literal = Note(title: "代码便签", body: "if a < b && b > c\n<custom>保留原文</custom>")
        check(literal.previewLines == ["if a < b && b > c", "<custom>保留原文</custom>"],
              "preview cleanup must only remove app formatting, not literal code or arbitrary tags")
    }

    private static func makeTextView(_ text: String) -> TaskTextView {
        let storage = NSTextStorage()
        let layout = HidingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        let tv = TaskTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        tv.isRichText = false; tv.allowsUndo = true; tv.string = text
        return tv
    }

    private static func style(_ tv: TaskTextView, markdown: Bool) {
        EditorStyleEngine.apply(to: tv, ranges: [NSRange(location: 0, length: tv.string.utf16.count)],
                                revealing: NSRange(location: 0, length: tv.string.utf16.count),
                                ink: .textColor, size: 14, markdownEnabled: markdown,
                                bodyFont: { NSFont.systemFont(ofSize: $0) }, isCompletedTask: { _ in false })
    }

    private static func testEditingAndUndo(check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        var saved = "中文与表情🙂"
        let tv = makeTextView(saved)
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        let bridge = EditorBridge(); bridge.textView = tv
        let wrapper = NoteTextView(text: Binding(get: { saved }, set: { saved = $0 }), ink: .textColor,
                                   bridge: bridge, autofocus: false)
        let coordinator = wrapper.makeCoordinator()
        tv.delegate = coordinator; coordinator.attach(to: tv)
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        guard let undo = tv.undoManager else { check(false, "editor must have an undo manager"); return }
        undo.groupsByEvent = false
        undo.beginUndoGrouping(); bridge.format(.bold); undo.endUndoGrouping()
        check(saved == tv.string && NoteFormatting.runs(in: saved).count == 1,
              "toolbar formatting must go through autosave")
        undo.undo()
        check(tv.string == "中文与表情🙂" && saved == tv.string, "undo must restore original content and save it")
        undo.redo()
        check(NoteFormatting.runs(in: tv.string).count == 1, "redo must restore formatting without nesting tags")
        undo.removeAllActions()
        undo.groupsByEvent = true
        let before = tv.string
        tv.isEditable = false; bridge.format(.underline)
        check(tv.string == before, "trash/read-only editors must reject formatting")
        tv.delegate = nil; tv.textStorage?.delegate = nil
        window.close()
    }

    private static func testInputPanelClicks(check: (Bool, String) -> Void) {
        let bounds = CGRect(x: -500, y: -200, width: 300, height: 400)
        let picker = EditorInputPanels.Window(bounds: bounds, bundleID: "com.apple.CharacterPaletteIM", alpha: 1)
        let point = CGPoint(x: -400, y: 0)
        check(EditorInputPanels.containsInputClick(targetBundleID: nil, at: point, windows: [picker]),
              "clicking the emoji picker on a secondary display must keep the note open")
        check(EditorInputPanels.containsInputClick(targetBundleID: "com.apple.CharacterPaletteIM", at: point, windows: []),
              "an emoji insertion click must remain recognized after the picker disappears")
        let app = EditorInputPanels.Window(bounds: bounds, bundleID: "com.apple.finder", alpha: 1)
        check(!EditorInputPanels.containsInputClick(targetBundleID: "com.apple.finder", at: point, windows: [app, picker]),
              "a picker covered by another app must not disable outside-click dismissal")
        check(!EditorInputPanels.containsInputClick(targetBundleID: nil, at: .zero, windows: [picker]),
              "clicks outside the picker must still dismiss an unpinned note")
        check(EditorInputPanels.isInputHelper("com.apple.inputmethod.SCIM"), "Chinese input candidates must be treated as editing UI")
        check(!EditorInputPanels.isInputHelper("com.apple.finder"), "ordinary apps must not be exempted from dismissal")
    }
}
