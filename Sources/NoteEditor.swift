import SwiftUI
import AppKit

// MARK: - Bridge to the underlying NSTextView (used for ⌘F)

final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    @Published var matchCount = 0

    func recount(_ q: String) {
        guard let tv = textView, !q.isEmpty else { matchCount = 0; return }
        let ns = tv.string as NSString
        var count = 0, loc = 0
        while loc < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            count += 1
            loc = r.location + max(1, r.length)
        }
        matchCount = count
    }

    func findNext(_ q: String, forward: Bool = true) {
        guard let tv = textView, !q.isEmpty else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var found: NSRange

        if forward {
            let start = min(ns.length, NSMaxRange(sel))
            found = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive])   // wrap
            }
        } else {
            found = ns.range(of: q, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: 0, length: sel.location))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive, .backwards])
            }
        }
        guard found.location != NSNotFound else { return }
        tv.setSelectedRange(found)
        tv.scrollRangeToVisible(found)
        tv.showFindIndicator(for: found)
    }

    /// Turn the caret's line into a task, or strip the checkbox back off it.
    func toggleTaskLine() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let text = ns.substring(with: line)

        if Tasks.isTask(text) {
            var length = 1
            if line.length > 1, ns.character(at: line.location + 1) == 32 { length = 2 }
            let range = NSRange(location: line.location, length: length)
            guard tv.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
        } else {
            let range = NSRange(location: line.location, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: Tasks.openPrefix) else { return }
            storage.replaceCharacters(in: range, with: Tasks.openPrefix)
        }
        tv.didChangeText()
    }

    func focusText() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// Collapses glyphs carrying `.notyHidden` to nothing. This is the only way to
/// hide characters without deleting them: colouring them clear still leaves
/// their width behind, and the caret still walks through them.
final class HidingLayoutManager: NSLayoutManager {
    override func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                            characterIndexes charIndexes: UnsafePointer<Int>,
                            font aFont: NSFont,
                            forGlyphRange glyphRange: NSRange) {
        guard let storage = textStorage else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
            return
        }
        var edited = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            guard ci < storage.length else { continue }
            if storage.attribute(.notyHidden, at: ci, effectiveRange: nil) != nil {
                edited[i] = .null
                changed = true
            }
        }
        guard changed else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
            return
        }
        edited.withUnsafeBufferPointer { buf in
            super.setGlyphs(glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes,
                            font: aFont, forGlyphRange: glyphRange)
        }
    }
}

// MARK: - NSTextView wrapper

/// Text view that treats a leading ☐ / ☑ as a real checkbox: clicking the box
/// toggles it, Return carries the list on, and finished lines get struck through.
final class TaskTextView: NSTextView {

    /// Owns the image overlays and the line-height delegate for image tokens.
    /// Installed by NoteTextView.makeNSView; kept on the view so the editor
    /// coordinator can refresh it after every style pass.
    var imageOverlays: NoteImageOverlayManager?

    /// The image token currently revealed for delete-confirmation, if any.
    /// Image markup is never shown just because the caret is near it; the only
    /// way to see the path is to press delete at the image, which selects the
    /// token text so a second delete removes it and a paste replaces it.
    var revealedImageID: String?

    override func deleteBackward(_ sender: Any?) {
        // A range selection means the user deliberately selected content —
        // delete it straight away, confirmation is for caret deletions only.
        if selectedRange().length == 0, let token = hiddenImageTokenAtDeletionPoint() {
            revealedImageID = token.id
            setSelectedRange(token.range)
            return
        }
        super.deleteBackward(sender)
    }

    /// While a token sits revealed for delete-confirmation its whole range
    /// stays selected; typing, Return or pasting would silently replace the
    /// markup and orphan the image. Treat those as "keep it": move the caret
    /// below the image, which makes the coordinator clear the reveal and
    /// re-hide the line.
    private func cancelImageRevealIfSelected() -> Bool {
        guard let id = revealedImageID, let storage = textStorage,
              let token = ImageStore.tokens(in: storage.string).first(where: { $0.id == id }),
              selectedRange() == token.range else { return false }
        var caret = NSMaxRange(token.range)
        if caret < storage.length, (storage.string as NSString).character(at: caret) == 10 {
            caret += 1
        }
        setSelectedRange(NSRange(location: caret, length: 0))
        return true
    }

    override func insertText(_ string: Any) {
        if cancelImageRevealIfSelected() { return }
        super.insertText(string)
    }

    override func insertNewline(_ sender: Any?) {
        if cancelImageRevealIfSelected() { return }
        super.insertNewline(sender)
    }

    /// Symmetric with backspace-after-the-image: forward-deleting INTO a
    /// hidden token reveals it for confirmation instead of eating a markup
    /// character the user cannot see.
    override func deleteForward(_ sender: Any?) {
        if selectedRange().length == 0, let storage = textStorage,
           let token = ImageStore.tokens(in: storage.string)
               .first(where: { $0.range.location == selectedRange().location }),
           storage.attribute(.notyHidden, at: token.range.location,
                             effectiveRange: nil) != nil {
            revealedImageID = token.id
            setSelectedRange(token.range)
            return
        }
        super.deleteForward(sender)
    }

    // MARK: Character-like image navigation

    /// A hidden image token collapses to zero glyphs but should still walk
    /// like one character: arrow keys never park the caret inside the dozens
    /// of invisible markup characters. Left/right snap to the edge in the
    /// direction of travel; up/down land on the nearer edge.
    override func moveRight(_ sender: Any?) {
        super.moveRight(sender)
        snapCaretOutOfHiddenImageToken(edge: .trailing)
    }

    override func moveLeft(_ sender: Any?) {
        super.moveLeft(sender)
        snapCaretOutOfHiddenImageToken(edge: .leading)
    }

    override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        snapCaretOutOfHiddenImageToken(edge: .nearest)
    }

    override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        snapCaretOutOfHiddenImageToken(edge: .nearest)
    }

    private enum ImageCaretEdge { case leading, trailing, nearest }

    private func snapCaretOutOfHiddenImageToken(edge: ImageCaretEdge) {
        guard let storage = textStorage else { return }
        let caret = selectedRange()
        guard caret.length == 0 else { return }
        for token in ImageStore.tokens(in: storage.string)
        where caret.location > token.range.location && caret.location < NSMaxRange(token.range) {
            guard storage.attribute(.notyHidden, at: token.range.location,
                                    effectiveRange: nil) != nil else { return }
            let target: Int
            switch edge {
            case .leading: target = token.range.location
            case .trailing: target = NSMaxRange(token.range)
            case .nearest:
                let mid = token.range.location + token.range.length / 2
                target = caret.location <= mid ? token.range.location : NSMaxRange(token.range)
            }
            setSelectedRange(NSRange(location: target, length: 0))
            return
        }
    }

    /// The hidden image token a caret-backspace would eat into, if any: the
    /// caret sits inside/right after the markup (arrow keys can walk it onto
    /// the collapsed line), or directly below the image where deleting would
    /// consume the token line's newline.
    private func hiddenImageTokenAtDeletionPoint() -> (id: String, width: CGFloat?, range: NSRange)? {
        guard let storage = textStorage else { return nil }
        let caret = selectedRange().location
        let ns = storage.string as NSString
        for token in ImageStore.tokens(in: storage.string) {
            guard token.range.location < storage.length,
                  storage.attribute(.notyHidden, at: token.range.location,
                                    effectiveRange: nil) != nil else { continue }
            if caret > token.range.location, caret <= NSMaxRange(token.range) { return token }
            if caret == NSMaxRange(token.range) + 1, caret > 0,
               ns.character(at: caret - 1) == 10 { return token }
        }
        return nil
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TaskTextView.wireEditMenu()
    }

    /// The Edit menu is built in AppDelegate, but the insert action belongs to
    /// whichever note has focus, so the item's target is left nil and travels
    /// the responder chain to this view.
    private static var editMenuWired = false

    private static func wireEditMenu() {
        guard !editMenuWired, let mainMenu = NSApp.mainMenu else { return }
        guard let edit = mainMenu.items.first(where: {
            $0.submenu?.title == L10n.text("menu.edit")
        })?.submenu else { return }
        let action = #selector(insertImageFromPanel(_:))
        guard !edit.items.contains(where: { $0.action == action }) else {
            editMenuWired = true
            return
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.text("menu.insert_image"),
                     action: action, keyEquivalent: "")
        editMenuWired = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleBox(at: point) { return }
        // ⌘-click follows a link. A plain click has to keep placing the caret —
        // the note is a thing you edit first and read second.
        if event.modifierFlags.contains(.command), openLink(at: point) { return }
        super.mouseDown(with: event)
    }

    /// Returns true when the click landed on a link and opened it.
    private func openLink(at point: NSPoint) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        guard let value = storage.attribute(.link, at: index, effectiveRange: nil) else { return false }
        // The engine only ever stores a vetted URL here, but this is the point
        // where a note's own text would reach NSWorkspace, so it is checked again.
        let raw = (value as? URL)?.absoluteString ?? value as? String
        guard let raw, let url = EditorStyleEngine.openableURL(raw) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer,
              let storage = textStorage else { return }
        let ns = storage.mutableString
        guard ns.length > 0, !visibleRect.isEmpty else { return }

        let origin = textContainerOrigin
        var containerVisible = visibleRect
        containerVisible.origin.x -= origin.x
        containerVisible.origin.y -= origin.y
        let visibleGlyphs = lm.glyphRange(forBoundingRect: containerVisible, in: tc)
        let visibleCharacters = lm.characterRange(forGlyphRange: visibleGlyphs,
                                                   actualGlyphRange: nil)
        let safeLocation = min(visibleCharacters.location, ns.length)
        let safeLength = min(visibleCharacters.length, ns.length - safeLocation)
        let lines = ns.lineRange(for: NSRange(location: safeLocation, length: safeLength))

        ns.enumerateSubstrings(in: lines,
                               options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.isTask(sub) else { return }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                       actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            r.origin.x += origin.x
            r.origin.y += origin.y
            self.addCursorRect(r.insetBy(dx: -3, dy: -2), cursor: .pointingHand)
        }
    }

    /// Returns true when the click landed on a checkbox and was consumed.
    private func toggleBox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let index = min(characterIndexForInsertion(at: point), max(0, ns.length - 1))
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        guard line.length > 0 else { return false }
        let first = ns.character(at: line.location)
        guard first == Tasks.open.unicodeScalars.first!.value ||
              first == Tasks.done.unicodeScalars.first!.value else { return false }

        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                   actualCharacterRange: nil)
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        guard box.insetBy(dx: -4, dy: -3).contains(point) else { return false }

        let target = NSRange(location: line.location, length: 1)
        let flipped = String(first == Tasks.open.unicodeScalars.first!.value ? Tasks.done : Tasks.open)
        guard shouldChangeText(in: target, replacementString: flipped) else { return true }
        storage.replaceCharacters(in: target, with: flipped)
        didChangeText()
        return true
    }

    // MARK: Images

    /// A plain-text view validates ⌘V off when the pasteboard holds only image
    /// data, which would keep paste(_:) from ever seeing it. Claim the command
    /// whenever the clipboard can provide an image.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if (item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:))),
           ImagePasteboard.canProvideImage(.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// An image on the pasteboard becomes a token on its own line; everything
    /// else keeps the plain-text paste behaviour.
    override func paste(_ sender: Any?) {
        if cancelImageRevealIfSelected() { return }
        let ids = ImagePasteboard.imageIDs(from: .general)
        guard !ids.isEmpty else {
            super.paste(sender)
            return
        }
        insertImageTokens(ids.map { ImageStore.token(id: $0, width: nil) })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImagePasteboard.canProvideImage(sender.draggingPasteboard)
            ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = ImagePasteboard.imageIDs(from: sender.draggingPasteboard)
        guard !ids.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        insertImageTokens(ids.map { ImageStore.token(id: $0, width: nil) })
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let item = NSMenuItem(title: L10n.text("menu.insert_image"),
                              action: #selector(insertImageFromPanel(_:)),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func insertImageFromPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { ImagePasteboard.saveFile(at: $0) }
        insertImageTokens(ids.map { ImageStore.token(id: $0, width: nil) })
    }

    /// Insert each token on its own line at the caret as one undoable edit —
    /// the same shouldChangeText / replaceCharacters / didChangeText pattern
    /// as EditorBridge.toggleTaskLine, so undo and the style pipeline see a
    /// normal text change. The caret lands on a fresh line BELOW the token:
    /// leaving it on the token's own line would trip the caret-line reveal and
    /// show raw markup instead of the image the user just dropped in.
    func insertImageTokens(_ tokens: [String]) {
        guard !tokens.isEmpty, let storage = textStorage else { return }
        let ns = storage.string as NSString
        var range = selectedRange()
        if range.location == NSNotFound { range = NSRange(location: ns.length, length: 0) }
        range = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let atLineStart = range.location == 0 || ns.character(at: range.location - 1) == 10
        let atLineEnd = NSMaxRange(range) >= ns.length
            || ns.character(at: NSMaxRange(range)) == 10
        var insertion = tokens.joined(separator: "\n") + "\n"
        if !atLineStart { insertion = "\n" + insertion }
        if !atLineEnd { insertion += "\n" }
        guard shouldChangeText(in: range, replacementString: insertion) else { return }
        storage.replaceCharacters(in: range, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (insertion as NSString).length,
                                 length: 0))
    }
}

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    let bridge: EditorBridge
    var autofocus: Bool
    var fontSize: CGFloat = 13.5
    var markdownEnabled: Bool = Settings.markdownStyling
    var textDirection: NoteTextDirection = .automatic
    /// Everything that affects how the text is drawn, as one cheap value. The
    /// alternative — comparing a freshly built NSColor and NSFont — is not
    /// reliably equal, so a full restyle ran on every re-render.
    var styleToken: String = ""

    static func bodyFont(_ size: CGFloat) -> NSFont { Ink.body(size) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // An explicit TextKit 1 stack: a plain NSTextView would get TextKit 2,
        // where NSLayoutManager — and so the glyph hiding — is never consulted.
        let storage = NSTextStorage()
        let layout = HidingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let tv = TaskTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.bodyFont(fontSize)
        tv.textColor = ink
        tv.insertionPointColor = ink
        tv.textContainerInset = NSSize(width: 15, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        // AppKit paints .link ranges system blue by default, which fights every
        // paper colour in the deck. Keep the underline and the cursor, and let
        // the note's own ink through.
        tv.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.string = text
        scroll.documentView = tv
        bridge.textView = tv
        let activeLine = EditorStyleEngine.lineRange(
            containing: tv.selectedRange().location, in: storage.mutableString)
        Self.applyStyles(to: tv,
                         ranges: [NSRange(location: 0, length: storage.length)],
                         revealing: activeLine,
                         ink: ink,
                         size: fontSize,
                         markdownEnabled: markdownEnabled,
                         textDirection: textDirection)
        Self.applyTextDirection(textDirection, to: tv)
        context.coordinator.attach(to: tv)
        let overlays = NoteImageOverlayManager()
        overlays.attach(to: tv, scrollView: scroll)
        tv.imageOverlays = overlays
        overlays.refresh()
        if autofocus {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.synchronize(tv)
        Self.applyTextDirection(textDirection, to: tv)
        if bridge.textView !== tv { bridge.textView = tv }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.delegate = nil
        tv.textStorage?.delegate = nil
    }

    static func applyTextDirection(_ direction: NoteTextDirection, to textView: NSTextView) {
        // Automatic is applied per paragraph by EditorStyleEngine. Assigning
        // NSTextView.alignment/baseWritingDirection here would rewrite every
        // paragraph back to AppKit's locale-based `.natural` alignment after
        // the engine had resolved its first strong character.
        guard direction != .automatic else { return }
        textView.baseWritingDirection = direction.writingDirection
        textView.alignment = direction.alignment
    }

    @discardableResult
    private static func applyStyles(to tv: NSTextView,
                                    ranges: [NSRange],
                                    revealing activeLine: NSRange?,
                                    ink: NSColor,
                                    size: CGFloat,
                                    markdownEnabled: Bool,
                                    textDirection: NoteTextDirection) -> [NSRange] {
        EditorStyleEngine.apply(to: tv,
                                ranges: ranges,
                                revealing: activeLine,
                                forceRevealImageID: (tv as? TaskTextView)?.revealedImageID,
                                ink: ink,
                                size: size,
                                markdownEnabled: markdownEnabled,
                                textDirection: textDirection,
                                bodyFont: bodyFont,
                                isCompletedTask: { Tasks.marker(of: $0) == Tasks.done })
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NoteTextView

        private var edits = EditorEditAccumulator()
        private var lastLine = NSRange(location: NSNotFound, length: 0)
        private var isApplyingStyles = false
        private var needsFullPass = false
        /// The style token last applied. Comparing one string beats rebuilding
        /// an NSColor and an NSFont and hoping they compare equal — they do not
        /// reliably, and every re-render then ran a full restyle.
        private var appliedStyle: String?

        init(_ p: NoteTextView) { parent = p }

        func attach(to tv: NSTextView) {
            tv.textStorage?.delegate = self
            lastLine = activeLine(in: tv)
            rememberConfiguration()
        }

        func synchronize(_ tv: NSTextView) {
            if tv.string != parent.text {
                // SwiftUI can update around every IME composition event. Never
                // replace the native string while the input method owns it.
                guard !tv.hasMarkedText() else {
                    needsFullPass = true
                    return
                }
                let selection = tv.selectedRange()
                isApplyingStyles = true
                tv.string = parent.text
                edits.clear()
                tv.setSelectedRange(clamped(selection, to: tv.string.utf16.count))
                isApplyingStyles = false
                needsFullPass = true
            }

            if configurationChanged() { needsFullPass = true }
            if needsFullPass { applyFullPassIfSafe(to: tv) }
        }

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard !isApplyingStyles, editedMask.contains(.editedCharacters) else { return }
            edits.record(editedRange)
        }

        /// Moving the caret to another line changes which markers are revealed.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingStyles,
                  let tv = notification.object as? NSTextView,
                  !tv.hasMarkedText() else { return }

            // TextKit can post a selection change while a character edit is
            // still being finalized. Touching attributes in that intermediate
            // state can leave the newly generated glyphs absent until a later
            // edit. Let textDidChange perform the one incremental style pass
            // after the edit notification has completed.
            guard !edits.hasPendingEdits else { return }

            let line = activeLine(in: tv)

            // A revealed (delete-confirmation) image token hides again once the
            // caret leaves its markup or the markup stops parsing as a token.
            if let taskView = tv as? TaskTextView, let id = taskView.revealedImageID {
                let token = ImageStore.tokens(in: taskView.string).first { $0.id == id }
                let caret = taskView.selectedRange()
                let inside = token.map { t in
                    // The reveal's whole-token selection counts as inside; a
                    // bare caret only up to the markup's end, so cancelling
                    // (caret parked just past it) still re-hides the line.
                    caret.length > 0
                        ? NSIntersectionRange(caret, t.range).length > 0
                        : caret.location >= t.range.location && caret.location < NSMaxRange(t.range)
                } ?? false
                if !inside {
                    taskView.revealedImageID = nil
                    let previous = lastLine
                    lastLine = line
                    applyIncremental([previous, line], to: tv, invalidateCursors: false)
                    return
                }
            }

            guard parent.markdownEnabled else {
                lastLine = line
                return
            }
            guard line.location != lastLine.location else { return }

            let previous = lastLine
            lastLine = line
            applyIncremental([previous, line], to: tv, invalidateCursors: false)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingStyles,
                  let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string

            // Binding updates are safe during composition; attributes, layout,
            // cursor rectangles, and selection writes are deliberately deferred.
            guard !tv.hasMarkedText() else { return }

            if needsFullPass {
                applyFullPassIfSafe(to: tv)
                return
            }
            let dirty = consumeEdits(in: tv)
            if !dirty.isEmpty {
                applyIncremental(dirty, to: tv, invalidateCursors: true)
            } else {
                lastLine = activeLine(in: tv)
            }
        }

        private func consumeEdits(in tv: NSTextView) -> [NSRange] {
            guard let storage = tv.textStorage else { return [] }
            return edits.consume(in: storage.mutableString, hasMarkedText: tv.hasMarkedText())
        }

        private func applyIncremental(_ ranges: [NSRange], to tv: NSTextView,
                                      invalidateCursors: Bool) {
            guard !tv.hasMarkedText(), !ranges.isEmpty else { return }

            let line = activeLine(in: tv)
            isApplyingStyles = true
            NoteTextView.applyStyles(to: tv,
                                     ranges: ranges,
                                     revealing: line,
                                     ink: parent.ink,
                                     size: parent.fontSize,
                                     markdownEnabled: parent.markdownEnabled,
                                     textDirection: parent.textDirection)
            isApplyingStyles = false
            lastLine = line
            // The hidden-token set may have changed; overlays and reserved line
            // heights are rebuilt from the freshly styled attributes.
            (tv as? TaskTextView)?.imageOverlays?.refresh()
            if invalidateCursors { tv.window?.invalidateCursorRects(for: tv) }
        }

        private func applyFullPassIfSafe(to tv: NSTextView) {
            guard !tv.hasMarkedText(), let storage = tv.textStorage else {
                needsFullPass = true
                return
            }

            let font = NoteTextView.bodyFont(parent.fontSize)
            let line = activeLine(in: tv)
            isApplyingStyles = true
            tv.textColor = parent.ink
            tv.insertionPointColor = parent.ink
            tv.font = font
            NoteTextView.applyStyles(to: tv,
                                     ranges: [NSRange(location: 0, length: storage.length)],
                                     revealing: line,
                                     ink: parent.ink,
                                     size: parent.fontSize,
                                     markdownEnabled: parent.markdownEnabled,
                                     textDirection: parent.textDirection)
            isApplyingStyles = false

            edits.clear()
            lastLine = line
            needsFullPass = false
            rememberConfiguration()
            (tv as? TaskTextView)?.imageOverlays?.refresh()
            tv.window?.invalidateCursorRects(for: tv)
        }

        private func activeLine(in tv: NSTextView) -> NSRange {
            guard let storage = tv.textStorage else {
                return NSRange(location: 0, length: 0)
            }
            return EditorStyleEngine.lineRange(containing: tv.selectedRange().location,
                                               in: storage.mutableString)
        }

        private func configurationChanged() -> Bool {
            appliedStyle != configurationToken
        }

        private func rememberConfiguration() {
            appliedStyle = configurationToken
        }

        private var configurationToken: String {
            "\(parent.styleToken)|\(parent.textDirection.rawValue)"
        }

        private func clamped(_ selection: NSRange, to length: Int) -> NSRange {
            let location = min(selection.location == NSNotFound ? length : selection.location, length)
            return NSRange(location: location,
                           length: min(selection.length, length - location))
        }

        /// Return on a task line starts the next task; on an empty one, ends the list.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = tv.string as NSString
            guard range.location <= ns.length else { return true }
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let text = ns.substring(with: line)
            guard Tasks.isTask(text) else { return true }

            if Tasks.stripped(text.trimmingCharacters(in: .newlines)).isEmpty {
                let clear = NSRange(location: line.location,
                                    length: min(line.length, ns.length - line.location))
                if tv.shouldChangeText(in: clear, replacementString: "") {
                    tv.textStorage?.replaceCharacters(in: clear, with: "")
                    tv.didChangeText()
                }
                return false
            }
            tv.insertText("\n" + Tasks.openPrefix, replacementRange: range)
            return false
        }
    }
}

// MARK: - Editor

struct NoteTextDirectionLabel: View {
    let direction: NoteTextDirection
    let foreground: Color

    var body: some View {
        Group {
            if let symbol = direction.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            } else {
                Text(L10n.text("direction.auto_short"))
                    .font(.system(size: 9.5, weight: .semibold))
            }
        }
        .foregroundStyle(foreground)
        .frame(width: direction == .automatic ? 27 : 18, height: 18)
        .contentShape(Rectangle())
    }
}

struct NoteTextDirectionMenu: View {
    let direction: NoteTextDirection
    let foreground: Color
    let select: (NoteTextDirection) -> Void

    var body: some View {
        Menu {
            ForEach(NoteTextDirection.allCases) { option in
                Button(option == direction ? "✓ \(option.title)" : option.title) {
                    select(option)
                }
            }
        } label: {
            NoteTextDirectionLabel(direction: direction, foreground: foreground)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Borderless menus use the control tint for their label on macOS,
        // overriding the label's foreground style (most visibly for "Auto").
        .tint(foreground)
        .fixedSize()
        .help(L10n.format("help.text_direction", direction.title))
    }
}

struct NoteEditorView: View {
    let note: Note
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    var onRight: Bool = true

    @ObservedObject private var store = NoteStore.shared
    private var text: String { store.note(id: note.id)?.body ?? "" }
    private var title: String { store.note(id: note.id)?.title ?? "" }
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { store.updateBody(id: note.id, body: $0) })
    }
    private var titleBinding: Binding<String> {
        Binding(get: { title }, set: { store.updateTitle(id: note.id, title: $0) })
    }
    @State private var detaching = false
    @FocusState private var findFocused: Bool
    @FocusState private var titleFocused: Bool

    private var pal: NoteColor { note.palette }

    var body: some View {
        HStack(spacing: 0) {
            if onRight { gutter; sheet } else { sheet; gutter }
        }
        .opacity(deck.detachingID == note.id ? 0 : 1)
        .frame(width: deck.noteSize.width, height: deck.noteSize.height)
        .background(
            noteShape
                .fill(LinearGradient(colors: [pal.paper, pal.paper.opacity(0.88)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.34), radius: 28, x: onRight ? -12 : 12, y: 12)
        )
        .clipShape(noteShape)
        .overlay(noteShape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .onChange(of: deck.findQuery) { _, q in
            if q != nil { findFocused = true } else { deck.bridge.focusText() }
        }
        .onDisappear { flush() }
    }

    /// Rounded where it leaves the deck, square where it meets the screen edge.
    private var noteShape: UnevenRoundedRectangle { edgeTabShape(onRight: onRight, radius: 14) }

    // MARK: The note itself

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            if deck.findQuery != nil { findBar }
            NoteTextView(text: textBinding, ink: NSColor(pal.ink),
                         bridge: deck.bridge, autofocus: true,
                         fontSize: deck.fontSize,
                         markdownEnabled: deck.markdown,
                         textDirection: note.textDirection,
                         styleToken: "\(note.color)|\(deck.fontSize)|\(Settings.noteFontName)|\(deck.markdown)")
            footer
        }
    }

    /// The note's own tab, carried along so it reads as growing out of the deck.
    ///
    /// `rotationEffect` is a render transform, not a layout one: a rotated label
    /// still *measures* at its unrotated width, so the tint has to be sized on its
    /// own and the label clipped into it, or the background bleeds across the note.
    private var gutter: some View {
        Rectangle()
            .fill(pal.dash.opacity(0.20))
            .frame(width: DeckGeom.gutterWidth)
            .overlay {
                Text(note.displayTitle.uppercased())
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pal.ink.opacity(0.7))
                    .frame(width: DeckGeom.editorHeight - 44)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
            }
            .clipped()
            .overlay(alignment: onRight ? .trailing : .leading) {
                EdgeLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(pal.ink.opacity(0.22))
                    .frame(width: 1)
            }
            // Grab the tab and pull the note off the deck: past the threshold
            // the floating panel takes over under the cursor, and the sheet
            // here hides but stays in the hierarchy — removing it would end
            // this very gesture mid-drag.
            .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { v in
                    if detaching {
                        FloatingNote.shared.dragTo(NSEvent.mouseLocation)
                    } else if (onRight ? -v.translation.width : v.translation.width) > 40 {
                        detaching = true
                        deck.isDragging = true
                        flush()
                        controller.detachExpandedNote(at: NSEvent.mouseLocation)
                    }
                }
                .onEnded { _ in
                    guard detaching else { return }
                    detaching = false
                    deck.isDragging = false
                    controller.finishDetach()
                })
    }

    private var header: some View {
        HStack(spacing: 8) {
            // No `prompt:` — a plain-style field draws its placeholder in the
            // system secondary label colour and ignores every modifier put on
            // it, which reads as white on the paper in dark mode. A derived
            // title always shows *as* the placeholder, so it has to be our own
            // Text, which styles like anything else.
            ZStack(alignment: .leading) {
                if title.isEmpty {
                    Text(note.hasCustomTitle ? L10n.text("note.title_prompt") : (Note.derivedTitle(from: text).isEmpty ? L10n.text("note.untitled") : Note.derivedTitle(from: text)))
                        .foregroundStyle(pal.ink.opacity(titleFocused ? 0.35 : 0.92))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: titleBinding)
                    .textFieldStyle(.plain)
                    .foregroundStyle(pal.ink.opacity(0.92))
                    .focused($titleFocused)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .tint(pal.ink)
            .onSubmit {
                flushTitle()
                deck.bridge.focusText()
            }
            .contextMenu {
                if note.hasCustomTitle {
                    Button(L10n.text("note.title_reset")) {
                        NoteStore.shared.updateTitle(id: note.id, title: "")
                    }
                }
            }

            Spacer(minLength: 6)
            Text(store.unsavedIDs.contains(note.id)
                 ? L10n.text("note.not_saved")
                 : L10n.format("note.saved", Fmt.ago(note.modified)))
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.42))
            Button { NoteStore.shared.togglePin(id: note.id) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? L10n.text("help.unpin") : L10n.text("help.pin"))

            NoteTextDirectionMenu(direction: note.textDirection,
                                  foreground: pal.ink.opacity(0.5)) {
                NoteStore.shared.setTextDirection(id: note.id, direction: $0)
            }

            Button { deck.bridge.toggleTaskLine() } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help(L10n.text("help.task"))
            Button { deck.findQuery = deck.findQuery == nil ? "" : nil } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help(L10n.text("help.find"))
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(pal.ink.opacity(0.45))
            TextField(L10n.text("note.find_placeholder"), text: Binding(
                get: { deck.findQuery ?? "" },
                set: { deck.findQuery = $0; deck.bridge.recount($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(pal.ink)
                .focused($findFocused)
                .onSubmit { deck.bridge.findNext(deck.findQuery ?? "") }
            Text(deck.bridge.matchCount == 0 ? "—" : "\(deck.bridge.matchCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(pal.ink.opacity(0.45))
            Button { deck.bridge.findNext(deck.findQuery ?? "", forward: false) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
            Button { deck.bridge.findNext(deck.findQuery ?? "") } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(pal.dash.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                Button { NoteStore.shared.setColor(id: note.id, color: idx) } label: {
                    Circle()
                        .fill(c.dash)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().strokeBorder(pal.ink.opacity(0.55),
                                                  lineWidth: idx == note.color ? 1.5 : 0)
                                .padding(-2.5)
                        )
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.localizedName)
            }
            Spacer(minLength: 8)
            footerButton(L10n.text("action.archive")) {
                NoteStore.shared.setArchived(id: note.id, true)
                controller.collapse()
            }
            footerButton(L10n.text("action.delete")) {
                NoteStore.shared.delete(id: note.id)
                controller.collapse()
            }
            footerButton(L10n.text("action.close")) { controller.collapse() }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(pal.ink.opacity(0.72))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pal.ink.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func flushTitle() { store.flush(id: note.id) }
    private func flush() { store.flush(id: note.id) }
}
