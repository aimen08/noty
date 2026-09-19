import AppKit

/// Checks for the image-token interaction model: tokens stay hidden no matter
/// where the caret is, arrow keys cross a token like one character, and delete
/// removes the whole image in one undoable step.
enum ImageInteractionTests {

    private static let tokenID = "ABC12345-1111-2222-3333-444455556666"
    private static var token: String { ImageStore.token(id: tokenID, width: nil) }

    static func run(_ check: (Bool, String) -> Void) {
        tokenStaysHiddenOnCaretLine(check)
        tokenLineReservesImageSize(check)
        arrowKeysSnapAcrossToken(check)
        deleteRemovesWholeToken(check)
        forwardDeleteRemovesWholeToken(check)
        deleteIsOneUndoStep(check)
        cropImageProducesValidAspectImage(check)
        cropWithNormalizedRectProducesExactSubimage(check)
        overlayHitTestConvertsSuperviewPoint(check)
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
    private static func style(_ tv: NSTextView, revealing: NSRange? = nil) -> [NSRange] {
        EditorStyleEngine.apply(to: tv,
                                ranges: [NSRange(location: 0, length: tv.textStorage?.length ?? 0)],
                                revealing: revealing,
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

    /// One backspace at the image deletes the whole token and its line break —
    /// no reveal step, no empty line left behind.
    private static func deleteRemovesWholeToken(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        // Caret on the line below the image.
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.deleteBackward(nil)
        check(tv.string.isEmpty, "delete below the image removes token and line break, got \(tv.string.debugDescription)")

        // Caret at the image's right edge, with text on both sides.
        let surrounded = "before\n" + token + "\nafter"
        let tv2 = makeView(surrounded)
        style(tv2)
        tv2.layoutManager?.ensureLayout(for: tv2.textContainer!)
        let tokenRange = ImageStore.tokens(in: surrounded).first!.range
        tv2.setSelectedRange(NSRange(location: NSMaxRange(tokenRange), length: 0))
        tv2.deleteBackward(nil)
        check(tv2.string == "before\nafter",
              "delete at the image edge lifts the whole line out, got \(tv2.string.debugDescription)")
    }

    /// Forward delete with the caret right before the image removes it whole.
    private static func forwardDeleteRemovesWholeToken(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        style(tv)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.deleteForward(nil)
        check(tv.string.isEmpty, "forward delete removes the token, got \(tv.string.debugDescription)")
    }

    /// The deletion must come back with a single ⌘Z, as one undo group. A text
    /// view only registers undo when a window supplies the undo manager, so
    /// this test parks the view in a real (offscreen) window.
    private static func deleteIsOneUndoStep(_ check: (Bool, String) -> Void) {
        let text = token + "\n"
        let tv = makeView(text)
        tv.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        style(tv)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)

        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        tv.deleteBackward(nil)
        check(tv.string.isEmpty, "token deleted before undo, got \(tv.string.debugDescription)")
        tv.undoManager?.undo()
        check(tv.string == text, "one undo restores the token, got \(tv.string.debugDescription)")
    }

    private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }   // matches NSTextView
    }

    /// hitTest is handed points in the SUPERVIEW's coordinate system. An
    /// overlay sitting away from the text origin must still answer hits —
    /// comparing the raw point against local frames once made every image
    /// below the first line unclickable.
    private static func overlayHitTestConvertsSuperviewPoint(_ check: (Bool, String) -> Void) {
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let overlay = NoteImageOverlayView(imageID: "x", image: nil)
        overlay.frame = NSRect(x: 20, y: 200, width: 200, height: 150)
        host.addSubview(overlay)

        overlay.setSelected(true)
        overlay.layoutSubtreeIfNeeded()

        // In the app the overlay's superview is the (flipped) text view, and
        // hitTest arrives in its coordinates — y grows downward. Call the
        // overlay's hitTest directly with exactly those coordinates: going
        // through a root host would add a root-level y-up conversion that
        // only exists in the test harness, not in the app.
        let centre = overlay.hitTest(NSPoint(x: 120, y: 275))
        check(centre === overlay, "overlay answers a hit at its centre, got \(String(describing: centre))")
        let outside = overlay.hitTest(NSPoint(x: 10, y: 10))
        check(outside === nil, "overlay ignores hits outside its bounds, got \(String(describing: outside))")
        let gripArea = overlay.hitTest(NSPoint(x: 216, y: 346))  // just inside the br grip
        check(gripArea != nil && gripArea !== overlay,
              "selected overlay exposes its grips, got \(String(describing: gripArea))")
        let barArea = overlay.hitTest(NSPoint(x: 120, y: 372))  // toolbar centre, container coords
        check(barArea != nil && barArea !== overlay,
              "selected overlay's toolbar is clickable, got \(String(describing: barArea))")
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

    /// Cropping an image to an aspect ratio produces a valid image with matching aspect ratio.
    private static func cropImageProducesValidAspectImage(_ check: (Bool, String) -> Void) {
        let sample = NSImage(size: NSSize(width: 200, height: 100))
        sample.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        sample.unlockFocus()

        guard let id = ImageStore.save(image: sample) else {
            check(false, "saving test image succeeded")
            return
        }
        defer { ImageStore.delete(ids: [id]) }

        guard let croppedID = ImageStore.crop(id: id, aspectRatio: 1.0) else {
            check(false, "cropping test image to 1:1 succeeded")
            return
        }
        defer { ImageStore.delete(ids: [croppedID]) }

        let croppedImage = ImageStore.image(id: croppedID)
        check(croppedImage != nil, "cropped image is retrievable")
        if let size = croppedImage?.size {
            check(abs(size.width - size.height) < 1.0,
                  "cropped 1:1 image has square dimensions, got \(size)")
        }
    }

    /// Cropping with an explicit normalized rect extracts precisely the selected sub-rectangle.
    private static func cropWithNormalizedRectProducesExactSubimage(_ check: (Bool, String) -> Void) {
        let sample = NSImage(size: NSSize(width: 200, height: 100))
        sample.lockFocus()
        NSColor.yellow.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        sample.unlockFocus()

        guard let id = ImageStore.save(image: sample) else {
            check(false, "saving test image succeeded")
            return
        }
        defer { ImageStore.delete(ids: [id]) }

        // Select top-left quarter: x: 0..0.5, y: 0..0.5 in top-down coordinates
        let normRect = NSRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        guard let croppedID = ImageStore.crop(id: id, normalizedRect: normRect) else {
            check(false, "crop with normalized rect succeeded")
            return
        }
        defer { ImageStore.delete(ids: [croppedID]) }

        guard let cropped = ImageStore.image(id: croppedID) else {
            check(false, "cropped sub-image is retrievable")
            return
        }
        check(abs(cropped.size.width - 100) < 1.0 && abs(cropped.size.height - 50) < 1.0,
              "cropped sub-image has expected 100x50 dimensions, got \(cropped.size)")
    }
}

