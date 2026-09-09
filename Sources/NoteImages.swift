import AppKit
import UniformTypeIdentifiers

// MARK: - Pasteboard / file intake

/// Turns drag-and-drop and pasteboard payloads into saved image ids. Files keep
/// their original encoding (a JPEG stays a JPEG); raw image data is re-encoded
/// by ImageStore.
enum ImagePasteboard {

    static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func saveFile(at url: URL) -> String? {
        guard isImageFile(url), let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        return ImageStore.save(data: data, ext: ext.isEmpty ? "png" : ext)
    }

    /// Save every image the pasteboard carries and return their ids. File URLs
    /// win over raw image data: dropping a file from Finder should not funnel
    /// its bytes through a TIFF re-encode.
    static func imageIDs(from pasteboard: NSPasteboard) -> [String] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let fileIDs = urls.compactMap { saveFile(at: $0) }
        if !fileIDs.isEmpty { return fileIDs }
        if let image = NSImage(pasteboard: pasteboard), let id = ImageStore.save(image: image) {
            return [id]
        }
        return []
    }

    /// Type check only — must not read file bytes the way `imageIDs` does, since
    /// it runs on every `draggingEntered`.
    static func canProvideImage(_ pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.contains(where: isImageFile) { return true }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}

// MARK: - Display metrics

/// How large an image token renders. The width the token records always wins;
/// an un-sized token falls back to the natural width capped so a screenshot can
/// never swallow the whole note.
enum NoteImageMetrics {
    /// Air above and below the image inside the inflated line fragment.
    static let verticalPadding: CGFloat = 3
    static let minWidth: CGFloat = 40
    static let defaultMaxWidth: CGFloat = 320

    static func displaySize(id: String, tokenWidth: CGFloat?, containerWidth: CGFloat)
        -> (width: CGFloat, height: CGFloat, hasFile: Bool) {
        let image = ImageStore.image(id: id)
        let natural = image?.size ?? .zero
        let usable = natural.width > 0 && natural.height > 0
        let cap = max(minWidth, containerWidth)
        let width: CGFloat
        if let tokenWidth, tokenWidth > 0 {
            width = min(max(minWidth, tokenWidth), cap)
        } else if usable {
            width = min(natural.width, cap, defaultMaxWidth)
        } else {
            // Missing file: the placeholder still needs a sensible footprint.
            width = min(160, cap)
        }
        let height = usable ? width * natural.height / natural.width : width * 0.6
        return (width, height, usable)
    }
}

// MARK: - Line-fragment inflation

/// TextKit 1 consults this delegate for every line fragment. A hidden image
/// token collapses to zero glyphs, which would leave the line one text-line
/// tall with the overlay spilling over the next paragraph — so the token's
/// line is inflated to the image's display height and the text below flows
/// around it.
final class ImageLineLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    /// Hidden token character ranges and the size each line must reserve.
    /// Rebuilt by the overlay manager after every style pass.
    var heights: [(range: NSRange, height: CGFloat, width: CGFloat)] = []

    /// Fires after layout so overlays can be re-anchored to their fragments.
    var onLayoutComplete: () -> Void = {}

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard !heights.isEmpty else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        for entry in heights where NSIntersectionRange(entry.range, charRange).length > 0 {
            var changed = false
            let needed = entry.height + NoteImageMetrics.verticalPadding * 2
            if lineFragmentUsedRect.pointee.height < needed {
                lineFragmentUsedRect.pointee.size.height = needed
                if lineFragmentRect.pointee.height < needed {
                    lineFragmentRect.pointee.size.height = needed
                }
                changed = true
            }
            // The collapsed token is zero glyphs wide; giving its used rect the
            // image's width lets the caret rest at the picture's right edge, so
            // the image arrow-keys and clicks like one big character.
            if lineFragmentUsedRect.pointee.width < entry.width {
                lineFragmentUsedRect.pointee.size.width = entry.width
                changed = true
            }
            return changed
        }
        return false
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       didCompleteLayoutFor textContainer: NSTextContainer?,
                       atEnd layoutFinishedFlag: Bool) {
        onLayoutComplete()
    }
}

// MARK: - Resize handle

/// The grip in an overlay's bottom-right corner. Runs its own event loop so the
/// drag stays smooth while the text reflows under it; reports the pointer in
/// text-view coordinates, once per event, with `finished` on mouse-up.
final class ImageResizeHandle: NSView {
    var onDrag: (_ point: NSPoint, _ finished: Bool) -> Void = { _, _ in }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func mouseDown(with event: NSEvent) {
        guard let window, let anchor = superview?.superview else { return }
        onDrag(anchor.convert(event.locationInWindow, from: nil), false)
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let point = anchor.convert(next.locationInWindow, from: nil)
            onDrag(point, next.type == .leftMouseUp)
            if next.type == .leftMouseUp { break }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3.5, dy: 3.5)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let marks = NSBezierPath()
        marks.lineWidth = 1
        // Two diagonal ticks read as "drag me" in either language direction.
        for inset: CGFloat in [2.5, 5.5] {
            marks.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + 1))
            marks.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + inset))
        }
        marks.stroke()
    }
}

// MARK: - Overlay view

/// One image token's visual stand-in: the image (or a dashed placeholder when
/// the file is gone), a hover-visible resize grip, and a selection ring. The
/// overlay only consumes clicks on its grip and for selection; everything else
/// in the text view belongs to the text.
final class NoteImageOverlayView: NSView {
    let imageID: String
    let hasFile: Bool

    var onSelect: (NoteImageOverlayView) -> Void = { _ in }
    var onDrag: (NSPoint, Bool) -> Void = { _, _ in }

    private let imageView = NSImageView()
    private let placeholderIcon = NSImageView()
    fileprivate let handle = ImageResizeHandle()
    private var trackingAreaRef: NSTrackingArea?
    private(set) var isSelected = false

    init(imageID: String, image: NSImage?) {
        self.imageID = imageID
        self.hasFile = image != nil
        super.init(frame: .zero)

        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.isHidden = image == nil
        addSubview(imageView)

        placeholderIcon.image = NSImage(systemSymbolName: "photo",
                                        accessibilityDescription: nil)
        placeholderIcon.contentTintColor = .secondaryLabelColor
        placeholderIcon.isHidden = image != nil
        addSubview(placeholderIcon)

        handle.onDrag = { [weak self] point, finished in
            self?.onDrag(point, finished)
        }
        handle.isHidden = true
        addSubview(handle)
    }

    required init?(coder: NSCoder) { fatalError("overlays are created in code") }

    override var isFlipped: Bool { true }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        needsDisplay = true
        handle.isHidden = !selected
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let iconSize: CGFloat = 22
        placeholderIcon.frame = NSRect(x: (bounds.width - iconSize) / 2,
                                       y: (bounds.height - iconSize) / 2,
                                       width: iconSize, height: iconSize)
        handle.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18,
                              width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { handle.isHidden = false }
    override func mouseExited(with event: NSEvent) { handle.isHidden = !isSelected }

    override func mouseDown(with event: NSEvent) {
        onSelect(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if !hasFile {
            // A deleted file must not vanish silently — the token in the text
            // still points at it, so the note shows where it used to be.
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            let dashed = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            dashed.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            dashed.stroke()
        }
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

// MARK: - Overlay manager

/// Keeps one overlay per hidden image token, anchored to the token's collapsed
/// glyph line. The plaintext token stays the source of truth; everything here
/// is derived view state that can be thrown away and rebuilt from the text.
final class NoteImageOverlayManager: NSObject {

    private struct Slot {
        let id: String
        let tokenRange: NSRange
        var width: CGFloat
        var height: CGFloat
        let hasFile: Bool
    }

    private weak var textView: TaskTextView?
    private let layoutDelegate = ImageLineLayoutDelegate()
    private var overlays: [String: NoteImageOverlayView] = [:]
    private var slots: [String: Slot] = [:]
    private var observers: [NSObjectProtocol] = []
    /// ensureLayout can complete layout synchronously, which re-enters here via
    /// the delegate callback; the flag keeps that from recursing.
    private var isRepositioning = false

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(to textView: TaskTextView, scrollView: NSScrollView) {
        self.textView = textView
        textView.layoutManager?.delegate = layoutDelegate
        layoutDelegate.onLayoutComplete = { [weak self] in self?.reposition() }

        // Scrolling moves every overlay; resizing re-wraps the text and can
        // change display widths (they are capped by the container), so a frame
        // change rebuilds metrics while a pure scroll only re-anchors.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: clip, queue: .main) { [weak self] _ in
            self?.reposition()
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                            object: clip, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    /// Called by the editor coordinator after each style pass: the hidden set
    /// may have changed, so rebuild the height table, reflow, and re-anchor.
    func refresh() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let oldRanges = layoutDelegate.heights.map(\.range)
        layoutDelegate.heights = currentTokens(in: storage).map {
            let size = displaySize(for: $0.token)
            return ($0.token.range, size.height, size.width)
        }
        let changed = oldRanges + layoutDelegate.heights.map(\.range)
        for range in changed where range.location != NSNotFound {
            tv.layoutManager?.invalidateLayout(forCharacterRange: range,
                                               actualCharacterRange: nil)
        }
        reposition()
    }

    // MARK: Resize

    /// Live: the overlay and the reserved line height follow the pointer; the
    /// text is only rewritten on mouse-up, so a cancelled drag costs nothing.
    private func handleDrag(_ key: String, point: NSPoint, finished: Bool) {
        guard let tv = textView, let overlay = overlays[key],
              var slot = slots[key], let storage = tv.textStorage else { return }
        let cap = tv.textContainer?.size.width ?? slot.width
        let width = min(max(NoteImageMetrics.minWidth,
                            point.x - overlay.frame.minX), max(NoteImageMetrics.minWidth, cap))
        guard abs(width - slot.width) > 0.25, slot.height > 0 else { return }
        let height = width * slot.height / slot.width
        slot.width = width
        slot.height = height
        slots[key] = slot
        overlay.frame.size = NSSize(width: width, height: height)

        if !finished {
            layoutDelegate.heights = layoutDelegate.heights.map {
                $0.range == slot.tokenRange
                    ? (range: $0.range, height: height, width: width) : $0
            }
            tv.layoutManager?.invalidateLayout(forCharacterRange: slot.tokenRange,
                                               actualCharacterRange: nil)
            return
        }
        commitWidth(width, for: slot, in: tv, storage: storage)
    }

    /// Rewrite the token's width field as one undoable edit. The token carries
    /// its own size, so a resize survives restarts and rides through export.
    private func commitWidth(_ width: CGFloat, for slot: Slot,
                             in tv: TaskTextView, storage: NSTextStorage) {
        // The drag reflowed the text; re-find the token by id near its last
        // known spot rather than trusting the stale range.
        let tokens = ImageStore.tokens(in: storage.string)
        guard let token = tokens.filter({ $0.id == slot.id })
            .min(by: { abs($0.range.location - slot.tokenRange.location)
                        < abs($1.range.location - slot.tokenRange.location) }) else { return }
        let replacement = ImageStore.token(id: token.id, width: width.rounded())
        guard (replacement as NSString) != (storage.string as NSString).substring(with: token.range) as NSString,
              tv.shouldChangeText(in: token.range, replacementString: replacement) else { return }
        let selection = tv.selectedRange()
        storage.replaceCharacters(in: token.range, with: replacement)
        tv.didChangeText()
        let delta = (replacement as NSString).length - token.range.length
        if delta != 0, selection.location > NSMaxRange(token.range) {
            tv.setSelectedRange(NSRange(location: selection.location + delta,
                                        length: selection.length))
        }
    }

    // MARK: Anchoring

    private func currentTokens(in storage: NSTextStorage)
        -> [(token: (id: String, width: CGFloat?, range: NSRange), hidden: Bool)] {
        let length = storage.length
        return ImageStore.tokens(in: storage.string).map { token in
            let hidden = token.range.location < length
                && storage.attribute(.notyHidden, at: token.range.location,
                                     effectiveRange: nil) != nil
            return (token, hidden)
        }.filter(\.hidden)
    }

    private func displaySize(for token: (id: String, width: CGFloat?, range: NSRange))
        -> (width: CGFloat, height: CGFloat, hasFile: Bool) {
        let container = textView?.textContainer?.size.width ?? NoteImageMetrics.defaultMaxWidth
        return NoteImageMetrics.displaySize(id: token.id, tokenWidth: token.width,
                                            containerWidth: container)
    }

    private func reposition() {
        guard !isRepositioning else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        guard let tv = textView, let storage = tv.textStorage,
              let lm = tv.layoutManager, let tc = tv.textContainer else {
                removeAll()
                return
        }

        var wanted: [String: (slot: Slot, frame: NSRect)] = [:]
        let origin = tv.textContainerOrigin
        for entry in currentTokens(in: storage) {
            let size = displaySize(for: entry.token)
            lm.ensureLayout(for: tc)
            let glyphs = lm.glyphRange(forCharacterRange: entry.token.range,
                                       actualCharacterRange: nil)
            guard glyphs.length > 0, glyphs.location != NSNotFound else { continue }
            let used = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location,
                                               effectiveRange: nil)
            guard used.height > 0 else { continue }
            let frame = NSRect(x: used.minX + origin.x,
                               y: used.minY + origin.y + NoteImageMetrics.verticalPadding,
                               width: size.width, height: size.height)
            let key = "\(entry.token.range.location):\(entry.token.id)"
            wanted[key] = (Slot(id: entry.token.id, tokenRange: entry.token.range,
                                width: size.width, height: size.height,
                                hasFile: size.hasFile), frame)
        }

        for (key, overlay) in overlays where wanted[key] == nil {
            overlay.removeFromSuperview()
            overlays.removeValue(forKey: key)
            slots.removeValue(forKey: key)
        }
        for (key, info) in wanted {
            slots[key] = info.slot
            if let overlay = overlays[key] {
                overlay.frame = info.frame
            } else {
                let overlay = NoteImageOverlayView(imageID: info.slot.id,
                                                   image: info.slot.hasFile
                                                       ? ImageStore.image(id: info.slot.id) : nil)
                overlay.frame = info.frame
                overlay.onSelect = { [weak self] picked in self?.select(picked) }
                overlay.onDrag = { [weak self] point, finished in
                    self?.handleDrag(key, point: point, finished: finished)
                }
                tv.addSubview(overlay)
                overlays[key] = overlay
            }
        }
    }

    private func select(_ picked: NoteImageOverlayView) {
        for (_, overlay) in overlays {
            overlay.setSelected(overlay === picked)
        }
        // Clicking the picture also parks the caret right after the token
        // line. Without this there is no way to point at an image and press
        // delete — the gesture that reveals its markup for confirmation.
        guard let key = overlays.first(where: { $0.value === picked })?.key,
              let slot = slots[key],
              let tv = textView, let storage = tv.textStorage else { return }
        let tokens = ImageStore.tokens(in: storage.string)
        guard let token = tokens.filter({ $0.id == slot.id })
            .min(by: { abs($0.range.location - slot.tokenRange.location)
                        < abs($1.range.location - slot.tokenRange.location) }) else { return }
        var caret = NSMaxRange(token.range)
        if caret < storage.length, (storage.string as NSString).character(at: caret) == 10 {
            caret += 1
        }
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    private func removeAll() {
        for (_, overlay) in overlays { overlay.removeFromSuperview() }
        overlays.removeAll()
        slots.removeAll()
        layoutDelegate.heights = []
    }
}
