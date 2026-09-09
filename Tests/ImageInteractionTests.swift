import AppKit

/// Checks for the image-token interaction model: tokens stay hidden no matter
/// where the caret is, arrow keys cross a token like one character, delete
/// reveals the markup for confirmation, and typing/Return cancels that reveal
/// instead of destroying the token.
enum ImageInteractionTests {

    private static let tokenID = "ABC12345-1111-2222-3333-444455556666"
    private static var token: String { ImageStore.token(id: tokenID, width: nil) }

    static func run(_ check: (Bool, String) -> Void) {
        tokenStaysHiddenOnCaretLine(check)
        forceRevealShowsToken(check)
        tokenLineReservesImageSize(check)
        arrowKeysSnapAcrossToken(check)
        deleteRevealsThenSecondDeleteRemoves(check)
        typingCancelsRevealWithoutTouchingToken(check)
        titlesAndPreviewsStripTokens(check)
    }

    // MARK: Helpers

    private static func makeView(_ source: String) -> TaskTextView {
        let storage = NSTextStorage(string: source)
        let layout = HidingLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return TaskTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500),
                            textContainer: container)
    }

    @discardableResult
    private static func style(_ tv: NSTextView, revealing: NSRange? = nil,
                              forceRevealImageID: String? = nil) -> [NSRange] {
        EditorStyleEngine.apply(to: tv,
                                ranges: [NSRange(location: 0, length: tv.textStorage?.length ?? 0)],
                                revealing: revealing,
                                forceRevealImageID: forceRevealImageID,
                                ink: .textColor,
                                size: 13.5,
                                markdownEnabled: true,
                                bodyFont: { NSFont.systemFont(ofSize: $0) },
                                isCompletedTask: { _ in false })
    }

    private static func isHidden(_ tv: NSTextView, at location: Int) -> Bool {
        tv.textStorage?.attribute(.notyHidden, at: location, effectiveRange: nil) != nil
    }

    // MARK: Tests

    /// The caret landing on the token line must NOT reveal the markup.
    private static func tokenStaysHiddenOnCaretLine(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        let tokenLine = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        style(tv, revealing: tokenLine)
        check(isHidden(tv, at: 0), "image token stays hidden when the caret is on its line")
    }

    /// The delete-confirmation path reveals exactly one token by id.
    private static func forceRevealShowsToken(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv, forceRevealImageID: tokenID)
        check(!isHidden(tv, at: 0), "force-revealed token is visible")
        style(tv)
        check(isHidden(tv, at: 0), "token hides again once the reveal id is gone")
    }

    /// The token's line fragment reserves the image's height AND width, so the
    /// caret can rest at the picture's right edge.
    private static func tokenLineReservesImageSize(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        guard let layout = tv.layoutManager, let container = tv.textContainer,
              let range = ImageStore.tokens(in: text).first?.range else {
            check(false, "token parses for layout test")
            return
        }
        let delegate = ImageLineLayoutDelegate()
        delegate.heights = [(range: range, height: 200, width: 320)]
        layout.delegate = delegate
        layout.ensureLayout(for: container)
        let used = layout.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
        check(used.height >= 206, "token line reserves image height, got \(used.height)")
        check(used.width >= 320, "token line reserves image width, got \(used.width)")
    }

    /// Left/right arrows cross the hidden token as one unit: below line →
    /// after image → before image → previous position, and back again.
    private static func arrowKeysSnapAcrossToken(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        let tokenRange = ImageStore.tokens(in: text).first!.range
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.moveLeft(nil)
        check(tv.selectedRange().location == NSMaxRange(tokenRange),
              "left from the line below lands after the image, got \(tv.selectedRange().location)")
        tv.moveLeft(nil)
        check(tv.selectedRange().location == tokenRange.location,
              "next left lands before the image, got \(tv.selectedRange().location)")
        tv.moveRight(nil)
        check(tv.selectedRange().location == NSMaxRange(tokenRange),
              "right from before the image lands after it, got \(tv.selectedRange().location)")
    }

    /// First delete reveals (selects) the token; second delete removes it.
    private static func deleteRevealsThenSecondDeleteRemoves(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        let tokenRange = ImageStore.tokens(in: text).first!.range
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.deleteBackward(nil)
        check(tv.string == text, "first delete leaves the text untouched")
        check(tv.selectedRange() == tokenRange, "first delete selects the whole token")
        check(tv.revealedImageID == tokenID, "first delete records the revealed id")

        tv.deleteBackward(nil)
        check(tv.string == "\n", "second delete removes the token, got \(tv.string.debugDescription)")
    }

    /// Typing (or Return/paste, same guard) while the token sits revealed
    /// cancels the reveal and keeps the markup intact.
    private static func typingCancelsRevealWithoutTouchingToken(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.deleteBackward(nil)
        tv.insertText(" ")
        check(tv.string == text, "typing during reveal does not replace the token")
        check(tv.selectedRange().location == (text as NSString).length,
              "cancel parks the caret below the image, got \(tv.selectedRange().location)")

        // Same guard on Return.
        tv.deleteBackward(nil)
        tv.insertNewline(nil)
        check(tv.string == text, "Return during reveal does not replace the token")
    }

    /// Titles and previews never show the raw path, even on mixed lines.
    private static func titlesAndPreviewsStripTokens(_ check: (Bool, String) -> Void) {
        let mixed = "call Dana \(token) about the lease"
        let title = Note.derivedTitle(from: mixed)
        check(!title.contains("noty-img"), "title strips an inline token, got \(title)")
        check(title.hasPrefix("call Dana"), "title keeps the words around the token, got \(title)")

        let leading = token + "\nactual content"
        check(Note.derivedTitle(from: leading) == "actual content",
              "token-only first line is skipped for the title")

        let note = Note(id: "t", title: "", body: mixed, color: 0)
        check(!note.preview.contains("noty-img"), "preview strips tokens, got \(note.preview)")
    }
}
