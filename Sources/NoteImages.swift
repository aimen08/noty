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

// MARK: - Grips and resize handles

/// The white square knob WeChat-style selection frames draw on the border.
/// Pure chrome: it never takes clicks, so the overlay underneath still
/// receives its selection mouseDown.
fileprivate class ImageGripView: NSView {
    static let side: CGFloat = 12
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        NSColor.white.setFill()
        path.fill()
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A grip that drags. Runs its own event loop so the drag stays smooth while
/// the text reflows under it; reports the pointer in text-view coordinates,
/// once per event, with `finished` on mouse-up.
fileprivate final class ImageResizeHandle: ImageGripView {
    var onDrag: (_ point: NSPoint, _ finished: Bool) -> Void = { _, _ in }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The point arrives in the superview's (the overlay's) coordinates —
        // the same space `frame` is expressed in, so no conversion here.
        let hitRect = frame.insetBy(dx: -4, dy: -4)
        return hitRect.contains(point) ? self : nil
    }

    /// Grips must drag on the first press even in a non-key panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        addCursorRect(bounds.insetBy(dx: -2, dy: -2), cursor: .resizeLeftRight)
    }
}

// MARK: - Interactive Crop Overlay View

/// An interactive crop box displayed directly over the image during crop mode.
/// Allows freeform dragging and resizing of the crop box, or aspect-ratio locked resizing,
/// with rule-of-thirds grid lines and semi-transparent dimming outside the crop box.
fileprivate final class ImageCropOverlayView: NSView {
    enum DragMode {
        case none
        case move
        case tl, tr, bl, br
        case tm, bm, ml, mr
    }

    var cropRect: NSRect = .zero {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var targetRatio: CGFloat? = nil  // width / height, nil = freeform

    private let minSide: CGFloat = 28

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetToFull() {
        targetRatio = nil
        cropRect = bounds.insetBy(dx: 2, dy: 2)
        needsDisplay = true
    }

    func applyRatio(_ ratio: CGFloat) {
        targetRatio = ratio
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return }
        let center = cropRect.width > 0 && cropRect.height > 0
            ? NSPoint(x: cropRect.midX, y: cropRect.midY)
            : NSPoint(x: bounds.midX, y: bounds.midY)

        var w = cropRect.width > 0 ? cropRect.width : bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        if w > bounds.width {
            w = bounds.width
            h = w / ratio
        }
        var x = center.x - w / 2
        var y = center.y - h / 2
        x = max(0, min(bounds.width - w, x))
        y = max(0, min(bounds.height - h, y))
        cropRect = NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
        needsDisplay = true
    }

    private func hitHandle(at point: NSPoint) -> DragMode {
        let r = cropRect
        guard r.width > 0, r.height > 0 else { return .none }
        let handleRadius: CGFloat = 14

        // Corners first
        if hypot(point.x - r.minX, point.y - r.minY) <= handleRadius { return .tl }
        if hypot(point.x - r.maxX, point.y - r.minY) <= handleRadius { return .tr }
        if hypot(point.x - r.minX, point.y - r.maxY) <= handleRadius { return .bl }
        if hypot(point.x - r.maxX, point.y - r.maxY) <= handleRadius { return .br }

        // Midpoints
        if abs(point.y - r.minY) <= 8 && abs(point.x - r.midX) <= 14 { return .tm }
        if abs(point.y - r.maxY) <= 8 && abs(point.x - r.midX) <= 14 { return .bm }
        if abs(point.x - r.minX) <= 8 && abs(point.y - r.midY) <= 14 { return .ml }
        if abs(point.x - r.maxX) <= 8 && abs(point.y - r.midY) <= 14 { return .mr }

        // Inside
        if r.contains(point) { return .move }

        return .none
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard cropRect.width > 0, cropRect.height > 0 else { return }

        // Inside move
        if cropRect.width > 24, cropRect.height > 24 {
            addCursorRect(cropRect.insetBy(dx: 12, dy: 12), cursor: .openHand)
        }

        // Corners
        let cSize: CGFloat = 16
        addCursorRect(NSRect(x: cropRect.minX - 8, y: cropRect.minY - 8, width: cSize, height: cSize), cursor: .crosshair)
        addCursorRect(NSRect(x: cropRect.maxX - 8, y: cropRect.minY - 8, width: cSize, height: cSize), cursor: .crosshair)
        addCursorRect(NSRect(x: cropRect.minX - 8, y: cropRect.maxY - 8, width: cSize, height: cSize), cursor: .crosshair)
        addCursorRect(NSRect(x: cropRect.maxX - 8, y: cropRect.maxY - 8, width: cSize, height: cSize), cursor: .crosshair)

        // Midpoints
        addCursorRect(NSRect(x: cropRect.midX - 8, y: cropRect.minY - 4, width: 16, height: 8), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: cropRect.midX - 8, y: cropRect.maxY - 4, width: 16, height: 8), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: cropRect.minX - 4, y: cropRect.midY - 8, width: 8, height: 16), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: cropRect.maxX - 4, y: cropRect.midY - 8, width: 8, height: 16), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startPoint = convert(event.locationInWindow, from: nil)
        let mode = hitHandle(at: startPoint)
        guard mode != .none else { return }
        let initR = cropRect

        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let point = convert(next.locationInWindow, from: nil)
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            updateCropRect(mode: mode, initR: initR, dx: dx, dy: dy)
            if next.type == .leftMouseUp { break }
        }
    }

    private func updateCropRect(mode: DragMode, initR: NSRect, dx: CGFloat, dy: CGFloat) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }

        switch mode {
        case .none:
            break
        case .move:
            var x = initR.minX + dx
            var y = initR.minY + dy
            x = max(0, min(b.width - initR.width, x))
            y = max(0, min(b.height - initR.height, y))
            cropRect = NSRect(x: round(x), y: round(y), width: initR.width, height: initR.height)

        case .br:
            var w = max(minSide, min(b.width - initR.minX, initR.width + dx))
            var h = max(minSide, min(b.height - initR.minY, initR.height + dy))
            if let ratio = targetRatio {
                let hFromW = w / ratio
                if initR.minY + hFromW <= b.height {
                    h = hFromW
                } else {
                    h = b.height - initR.minY
                    w = h * ratio
                }
            }
            cropRect = NSRect(x: initR.minX, y: initR.minY, width: round(w), height: round(h))

        case .bl:
            var x = min(initR.maxX - minSide, max(0, initR.minX + dx))
            var w = initR.maxX - x
            var h = max(minSide, min(b.height - initR.minY, initR.height + dy))
            if let ratio = targetRatio {
                h = w / ratio
                if initR.minY + h > b.height {
                    h = b.height - initR.minY
                    w = h * ratio
                    x = initR.maxX - w
                }
            }
            cropRect = NSRect(x: round(x), y: initR.minY, width: round(w), height: round(h))

        case .tr:
            var y = min(initR.maxY - minSide, max(0, initR.minY + dy))
            var h = initR.maxY - y
            var w = max(minSide, min(b.width - initR.minX, initR.width + dx))
            if let ratio = targetRatio {
                w = h * ratio
                if initR.minX + w > b.width {
                    w = b.width - initR.minX
                    h = w / ratio
                    y = initR.maxY - h
                }
            }
            cropRect = NSRect(x: initR.minX, y: round(y), width: round(w), height: round(h))

        case .tl:
            var x = min(initR.maxX - minSide, max(0, initR.minX + dx))
            var y = min(initR.maxY - minSide, max(0, initR.minY + dy))
            var w = initR.maxX - x
            var h = initR.maxY - y
            if let ratio = targetRatio {
                let hFromW = w / ratio
                if initR.maxY - hFromW >= 0 {
                    h = hFromW
                    y = initR.maxY - h
                } else {
                    h = initR.maxY
                    w = h * ratio
                    x = initR.maxX - w
                    y = 0
                }
            }
            cropRect = NSRect(x: round(x), y: round(y), width: round(w), height: round(h))

        case .mr:
            var w = max(minSide, min(b.width - initR.minX, initR.width + dx))
            if let ratio = targetRatio {
                var h = w / ratio
                if h > b.height { h = b.height; w = h * ratio }
                let y = max(0, min(b.height - h, initR.midY - h / 2))
                cropRect = NSRect(x: initR.minX, y: round(y), width: round(w), height: round(h))
            } else {
                cropRect = NSRect(x: initR.minX, y: initR.minY, width: round(w), height: initR.height)
            }

        case .ml:
            var x = min(initR.maxX - minSide, max(0, initR.minX + dx))
            var w = initR.maxX - x
            if let ratio = targetRatio {
                var h = w / ratio
                if h > b.height { h = b.height; w = h * ratio; x = initR.maxX - w }
                let y = max(0, min(b.height - h, initR.midY - h / 2))
                cropRect = NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
            } else {
                cropRect = NSRect(x: round(x), y: initR.minY, width: round(w), height: initR.height)
            }

        case .bm:
            var h = max(minSide, min(b.height - initR.minY, initR.height + dy))
            if let ratio = targetRatio {
                var w = h * ratio
                if w > b.width { w = b.width; h = w / ratio }
                let x = max(0, min(b.width - w, initR.midX - w / 2))
                cropRect = NSRect(x: round(x), y: initR.minY, width: round(w), height: round(h))
            } else {
                cropRect = NSRect(x: initR.minX, y: initR.minY, width: initR.width, height: round(h))
            }

        case .tm:
            var y = min(initR.maxY - minSide, max(0, initR.minY + dy))
            var h = initR.maxY - y
            if let ratio = targetRatio {
                var w = h * ratio
                if w > b.width { w = b.width; h = w / ratio; y = initR.maxY - h }
                let x = max(0, min(b.width - w, initR.midX - w / 2))
                cropRect = NSRect(x: round(x), y: round(y), width: round(w), height: round(h))
            } else {
                cropRect = NSRect(x: initR.minX, y: round(y), width: initR.width, height: round(h))
            }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cropRect.width > 0, cropRect.height > 0 else { return }

        // 1. Dim outside region using 4 rects
        NSColor.black.withAlphaComponent(0.55).setFill()
        if cropRect.minY > 0 {
            NSRect(x: 0, y: 0, width: bounds.width, height: cropRect.minY).fill()
        }
        if cropRect.maxY < bounds.height {
            NSRect(x: 0, y: cropRect.maxY, width: bounds.width, height: bounds.height - cropRect.maxY).fill()
        }
        if cropRect.minX > 0 {
            NSRect(x: 0, y: cropRect.minY, width: cropRect.minX, height: cropRect.height).fill()
        }
        if cropRect.maxX < bounds.width {
            NSRect(x: cropRect.maxX, y: cropRect.minY, width: bounds.width - cropRect.maxX, height: cropRect.height).fill()
        }

        // 2. Crop box border
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()

        // 3. Rule-of-thirds grid
        let gridPath = NSBezierPath()
        let oneThirdX = cropRect.minX + cropRect.width / 3.0
        let twoThirdX = cropRect.minX + cropRect.width * 2.0 / 3.0
        let oneThirdY = cropRect.minY + cropRect.height / 3.0
        let twoThirdY = cropRect.minY + cropRect.height * 2.0 / 3.0

        gridPath.move(to: NSPoint(x: oneThirdX, y: cropRect.minY))
        gridPath.line(to: NSPoint(x: oneThirdX, y: cropRect.maxY))
        gridPath.move(to: NSPoint(x: twoThirdX, y: cropRect.minY))
        gridPath.line(to: NSPoint(x: twoThirdX, y: cropRect.maxY))

        gridPath.move(to: NSPoint(x: cropRect.minX, y: oneThirdY))
        gridPath.line(to: NSPoint(x: cropRect.maxX, y: oneThirdY))
        gridPath.move(to: NSPoint(x: cropRect.minX, y: twoThirdY))
        gridPath.line(to: NSPoint(x: cropRect.maxX, y: twoThirdY))

        gridPath.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.35).setStroke()
        gridPath.stroke()

        // 4. Corner bracket handles (L-shaped, 14pt arm, 3pt stroke)
        let arm: CGFloat = 14
        let cornerPath = NSBezierPath()
        // Top-Left
        cornerPath.move(to: NSPoint(x: cropRect.minX, y: cropRect.minY + arm))
        cornerPath.line(to: NSPoint(x: cropRect.minX, y: cropRect.minY))
        cornerPath.line(to: NSPoint(x: cropRect.minX + arm, y: cropRect.minY))
        // Top-Right
        cornerPath.move(to: NSPoint(x: cropRect.maxX - arm, y: cropRect.minY))
        cornerPath.line(to: NSPoint(x: cropRect.maxX, y: cropRect.minY))
        cornerPath.line(to: NSPoint(x: cropRect.maxX, y: cropRect.minY + arm))
        // Bottom-Left
        cornerPath.move(to: NSPoint(x: cropRect.minX, y: cropRect.maxY - arm))
        cornerPath.line(to: NSPoint(x: cropRect.minX, y: cropRect.maxY))
        cornerPath.line(to: NSPoint(x: cropRect.minX + arm, y: cropRect.maxY))
        // Bottom-Right
        cornerPath.move(to: NSPoint(x: cropRect.maxX - arm, y: cropRect.maxY))
        cornerPath.line(to: NSPoint(x: cropRect.maxX, y: cropRect.maxY))
        cornerPath.line(to: NSPoint(x: cropRect.maxX, y: cropRect.maxY - arm))

        cornerPath.lineWidth = 3.0
        NSColor.white.setStroke()
        cornerPath.stroke()

        // 5. Edge midpoint handles (14pt bar)
        let midBarPath = NSBezierPath()
        midBarPath.move(to: NSPoint(x: cropRect.midX - arm / 2, y: cropRect.minY))
        midBarPath.line(to: NSPoint(x: cropRect.midX + arm / 2, y: cropRect.minY))
        midBarPath.move(to: NSPoint(x: cropRect.midX - arm / 2, y: cropRect.maxY))
        midBarPath.line(to: NSPoint(x: cropRect.midX + arm / 2, y: cropRect.maxY))
        midBarPath.move(to: NSPoint(x: cropRect.minX, y: cropRect.midY - arm / 2))
        midBarPath.line(to: NSPoint(x: cropRect.minX, y: cropRect.midY + arm / 2))
        midBarPath.move(to: NSPoint(x: cropRect.maxX, y: cropRect.midY - arm / 2))
        midBarPath.line(to: NSPoint(x: cropRect.maxX, y: cropRect.midY + arm / 2))

        midBarPath.lineWidth = 3.0
        NSColor.white.setStroke()
        midBarPath.stroke()
    }
}

// MARK: - Floating Toolbar

/// Compact floating pill toolbar displayed when an image is selected, providing
/// normal actions: Crop (裁切), Width (宽度), Copy (复制),
/// or crop-mode actions: Ratio (比例 ▾), Full (全图), Cancel (取消), Done (完成).
fileprivate final class NoteImageToolbarView: NSView {
    var onStartCrop: () -> Void = {}
    var onCropRatioSelected: (CGFloat?) -> Void = { _ in }
    var onResetCropBox: () -> Void = {}
    var onCommitCrop: () -> Void = {}
    var onCancelCrop: () -> Void = {}
    var onSetWidthFraction: (CGFloat) -> Void = { _ in }
    var onCopy: () -> Void = {}

    private(set) var isCropping = false

    // Normal mode views
    private let cropButton = NSButton()
    private let widthButton = NSButton()
    private let copyButton = NSButton()
    private let separator1 = NSBox()
    private let separator2 = NSBox()

    // Crop mode views
    private let cropRatioButton = NSButton()
    private let cropResetButton = NSButton()
    private let cropSeparator = NSBox()
    private let cropCancelButton = NSButton()
    private let cropDoneButton = NSButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        layer?.borderWidth = 1

        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupView() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)

        // --- Normal Mode ---
        cropButton.title = "裁切"
        cropButton.font = font
        cropButton.isBordered = false
        cropButton.contentTintColor = .white
        cropButton.target = self
        cropButton.action = #selector(handleStartCrop)
        if let icon = NSImage(systemSymbolName: "crop", accessibilityDescription: "裁切") {
            let conf = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            cropButton.image = icon.withSymbolConfiguration(conf)
            cropButton.imagePosition = .imageLeading
        }
        cropButton.frame = NSRect(x: 8, y: 2, width: 56, height: 24)
        addSubview(cropButton)

        separator1.boxType = .custom
        separator1.borderWidth = 0
        separator1.fillColor = NSColor.white.withAlphaComponent(0.25)
        separator1.frame = NSRect(x: 69, y: 6, width: 1, height: 16)
        addSubview(separator1)

        widthButton.title = "宽度 ▾"
        widthButton.font = font
        widthButton.isBordered = false
        widthButton.contentTintColor = .white
        widthButton.target = self
        widthButton.action = #selector(handleWidth(_:))
        if let icon = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: "宽度") {
            let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            widthButton.image = icon.withSymbolConfiguration(conf)
            widthButton.imagePosition = .imageLeading
        }
        widthButton.frame = NSRect(x: 74, y: 2, width: 68, height: 24)
        addSubview(widthButton)

        separator2.boxType = .custom
        separator2.borderWidth = 0
        separator2.fillColor = NSColor.white.withAlphaComponent(0.25)
        separator2.frame = NSRect(x: 147, y: 6, width: 1, height: 16)
        addSubview(separator2)

        copyButton.title = ""
        copyButton.isBordered = false
        copyButton.contentTintColor = .white
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.toolTip = "复制图片"
        if let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制图片") {
            let conf = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            copyButton.image = icon.withSymbolConfiguration(conf)
            copyButton.imagePosition = .imageOnly
        }
        copyButton.frame = NSRect(x: 152, y: 2, width: 28, height: 24)
        addSubview(copyButton)

        // --- Crop Mode ---
        cropRatioButton.title = "比例 ▾"
        cropRatioButton.font = font
        cropRatioButton.isBordered = false
        cropRatioButton.contentTintColor = .white
        cropRatioButton.target = self
        cropRatioButton.action = #selector(handleCropRatioMenu(_:))
        if let icon = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: "比例") {
            let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            cropRatioButton.image = icon.withSymbolConfiguration(conf)
            cropRatioButton.imagePosition = .imageLeading
        }
        cropRatioButton.frame = NSRect(x: 8, y: 2, width: 68, height: 24)
        cropRatioButton.isHidden = true
        addSubview(cropRatioButton)

        cropResetButton.title = "全图"
        cropResetButton.font = font
        cropResetButton.isBordered = false
        cropResetButton.contentTintColor = .white
        cropResetButton.target = self
        cropResetButton.action = #selector(handleResetCropBox)
        if let icon = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "全图") {
            let conf = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .medium)
            cropResetButton.image = icon.withSymbolConfiguration(conf)
            cropResetButton.imagePosition = .imageLeading
        }
        cropResetButton.frame = NSRect(x: 80, y: 2, width: 54, height: 24)
        cropResetButton.isHidden = true
        addSubview(cropResetButton)

        cropSeparator.boxType = .custom
        cropSeparator.borderWidth = 0
        cropSeparator.fillColor = NSColor.white.withAlphaComponent(0.25)
        cropSeparator.frame = NSRect(x: 138, y: 6, width: 1, height: 16)
        cropSeparator.isHidden = true
        addSubview(cropSeparator)

        cropCancelButton.title = "取消"
        cropCancelButton.font = font
        cropCancelButton.isBordered = false
        cropCancelButton.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
        cropCancelButton.target = self
        cropCancelButton.action = #selector(handleCancelCrop)
        cropCancelButton.frame = NSRect(x: 143, y: 2, width: 52, height: 24)
        cropCancelButton.isHidden = true
        addSubview(cropCancelButton)

        cropDoneButton.title = "完成"
        cropDoneButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        cropDoneButton.isBordered = false
        cropDoneButton.contentTintColor = .controlAccentColor
        cropDoneButton.target = self
        cropDoneButton.action = #selector(handleCommitCrop)
        if let icon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "完成") {
            let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            cropDoneButton.image = icon.withSymbolConfiguration(conf)
            cropDoneButton.imagePosition = .imageTrailing
        }
        cropDoneButton.frame = NSRect(x: 199, y: 2, width: 53, height: 24)
        cropDoneButton.isHidden = true
        addSubview(cropDoneButton)
    }

    func setMode(cropping: Bool) {
        isCropping = cropping
        cropButton.isHidden = cropping
        separator1.isHidden = cropping
        widthButton.isHidden = cropping
        separator2.isHidden = cropping
        copyButton.isHidden = cropping

        cropRatioButton.isHidden = !cropping
        cropResetButton.isHidden = !cropping
        cropSeparator.isHidden = !cropping
        cropCancelButton.isHidden = !cropping
        cropDoneButton.isHidden = !cropping

        frame.size.width = cropping ? 260 : 190
        needsDisplay = true
    }

    @objc private func handleStartCrop() { onStartCrop() }
    @objc private func handleCopy() { onCopy() }
    @objc private func handleResetCropBox() { onResetCropBox() }
    @objc private func handleCancelCrop() { onCancelCrop() }
    @objc private func handleCommitCrop() { onCommitCrop() }

    @objc private func handleCropRatioMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = true

        let rFree = NSMenuItem(title: "自由 (任意框选)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        rFree.target = self
        rFree.representedObject = nil
        menu.addItem(rFree)

        menu.addItem(.separator())

        let r1 = NSMenuItem(title: "1:1 (正方形)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        r1.target = self
        r1.representedObject = CGFloat(1.0)
        menu.addItem(r1)

        let r2 = NSMenuItem(title: "4:3 (标准横屏)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        r2.target = self
        r2.representedObject = CGFloat(4.0 / 3.0)
        menu.addItem(r2)

        let r3 = NSMenuItem(title: "16:9 (宽屏)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        r3.target = self
        r3.representedObject = CGFloat(16.0 / 9.0)
        menu.addItem(r3)

        let r4 = NSMenuItem(title: "3:4 (标准竖屏)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        r4.target = self
        r4.representedObject = CGFloat(3.0 / 4.0)
        menu.addItem(r4)

        let r5 = NSMenuItem(title: "9:16 (手机竖屏)", action: #selector(applyRatioItem(_:)), keyEquivalent: "")
        r5.target = self
        r5.representedObject = CGFloat(9.0 / 16.0)
        menu.addItem(r5)

        let point = NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func handleWidth(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = true

        let w100 = NSMenuItem(title: "100% (满宽)", action: #selector(applyWidthFractionItem(_:)), keyEquivalent: "")
        w100.target = self
        w100.representedObject = CGFloat(1.0)
        menu.addItem(w100)

        let w75 = NSMenuItem(title: "75%", action: #selector(applyWidthFractionItem(_:)), keyEquivalent: "")
        w75.target = self
        w75.representedObject = CGFloat(0.75)
        menu.addItem(w75)

        let w50 = NSMenuItem(title: "50%", action: #selector(applyWidthFractionItem(_:)), keyEquivalent: "")
        w50.target = self
        w50.representedObject = CGFloat(0.5)
        menu.addItem(w50)

        let point = NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func applyRatioItem(_ item: NSMenuItem) {
        let ratio = item.representedObject as? CGFloat
        onCropRatioSelected(ratio)
    }

    @objc private func applyWidthFractionItem(_ item: NSMenuItem) {
        if let fraction = item.representedObject as? CGFloat {
            onSetWidthFraction(fraction)
        }
    }
}

// MARK: - Overlay view

/// One image token's visual stand-in: the image (or a dashed placeholder when
/// the file is gone) and, when selected, a WeChat-style selection frame — a
/// crisp border line with square grips on all four corners and edge midpoints.
/// The image is anchored to the left edge and keeps its aspect ratio, so only
/// the three right-side grips drag; the rest are chrome. The overlay only
/// consumes clicks on a resize grip and for selection; everything else in the
/// text view belongs to the text.
final class NoteImageOverlayView: NSView {
    let imageID: String
    let hasFile: Bool

    var onSelect: (NoteImageOverlayView) -> Void = { _ in }
    var onDrag: (NSPoint, Bool) -> Void = { _, _ in }
    var onApplyCrop: (NSRect) -> Void = { _ in }
    var onSetWidthFraction: (CGFloat) -> Void = { _ in }
    var onCopy: () -> Void = {}

    private(set) var isCropping = false

    /// The eight frame anchors, WeChat-screenshot style. Left-edge grips stay
    /// decorative because the image's left edge is anchored to the line.
    private enum GripPos: CaseIterable {
        case tl, tm, tr, ml, mr, bl, bm, br

        var resizable: Bool { self == .tr || self == .mr || self == .br }

        func center(in b: NSRect) -> NSPoint {
            let x: CGFloat = switch self {
            case .tl, .ml, .bl: b.minX
            case .tm, .bm: b.midX
            case .tr, .mr, .br: b.maxX
            }
            let y: CGFloat = switch self {
            case .tl, .tm, .tr: b.minY
            case .ml, .mr: b.midY
            case .bl, .bm, .br: b.maxY
            }
            return NSPoint(x: x, y: y)
        }
    }

    private let imageView = NSImageView()
    private let placeholderIcon = NSImageView()
    private var grips: [GripPos: NSView] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    private(set) var isSelected = false
    private let toolbar = NoteImageToolbarView()
    private let cropOverlay = ImageCropOverlayView()

    /// Live dimensions while a resize drag runs, so the target size is never
    /// a guess. Hidden the moment the drag commits.
    private let sizeBadge: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.masksToBounds = true
        field.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.isHidden = true
        return field
    }()

    init(imageID: String, image: NSImage?) {
        self.imageID = imageID
        self.hasFile = image != nil
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)

        placeholderIcon.image = NSImage(systemSymbolName: "photo.badge.exclamationmark",
                                        accessibilityDescription: "图片缺失")
        placeholderIcon.contentTintColor = .secondaryLabelColor
        placeholderIcon.isHidden = image != nil
        addSubview(placeholderIcon)

        cropOverlay.isHidden = true
        addSubview(cropOverlay)

        for pos in GripPos.allCases {
            let grip: NSView
            if pos.resizable {
                let drag = ImageResizeHandle()
                drag.onDrag = { [weak self] point, finished in
                    self?.onDrag(point, finished)
                }
                grip = drag
            } else {
                grip = ImageGripView()
            }
            grip.isHidden = true
            grips[pos] = grip
            addSubview(grip)
        }

        addSubview(sizeBadge)

        toolbar.isHidden = true
        toolbar.onStartCrop = { [weak self] in self?.startCropping() }
        toolbar.onCropRatioSelected = { [weak self] ratio in
            if let ratio {
                self?.cropOverlay.applyRatio(ratio)
            } else {
                self?.cropOverlay.targetRatio = nil
            }
        }
        toolbar.onResetCropBox = { [weak self] in self?.cropOverlay.resetToFull() }
        toolbar.onCommitCrop = { [weak self] in self?.commitCropping() }
        toolbar.onCancelCrop = { [weak self] in self?.cancelCropping() }
        toolbar.onSetWidthFraction = { [weak self] f in self?.onSetWidthFraction(f) }
        toolbar.onCopy = { [weak self] in self?.onCopy() }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) {
        fatalError("overlays are created in code, not from nibs")
    }

    override var isFlipped: Bool { true }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        if !selected && isCropping {
            cancelCropping()
        }
        needsDisplay = true
        for (_, grip) in grips { grip.isHidden = !selected || isCropping }
        toolbar.isHidden = !selected
        if !selected { sizeBadge.isHidden = true }
    }

    func showSize(width: CGFloat, height: CGFloat) {
        sizeBadge.stringValue = "\(Int(width.rounded())) × \(Int(height.rounded()))"
        sizeBadge.isHidden = false
        needsLayout = true
    }

    func hideSize() { sizeBadge.isHidden = true }

    // MARK: - Crop Mode Controls

    func startCropping(ratio: CGFloat? = nil) {
        guard hasFile else { return }
        isCropping = true
        for (_, grip) in grips { grip.isHidden = true }
        cropOverlay.frame = bounds
        cropOverlay.isHidden = false
        if let ratio {
            cropOverlay.applyRatio(ratio)
        } else {
            cropOverlay.resetToFull()
        }
        toolbar.setMode(cropping: true)
        needsLayout = true
        needsDisplay = true
    }

    func cancelCropping() {
        guard isCropping else { return }
        isCropping = false
        cropOverlay.isHidden = true
        if isSelected {
            for (_, grip) in grips { grip.isHidden = false }
        }
        toolbar.setMode(cropping: false)
        needsLayout = true
        needsDisplay = true
    }

    func commitCropping() {
        guard isCropping, bounds.width > 0, bounds.height > 0 else { return }
        let r = cropOverlay.cropRect
        let norm = NSRect(x: r.minX / bounds.width,
                          y: r.minY / bounds.height,
                          width: r.width / bounds.width,
                          height: r.height / bounds.height)
        cancelCropping()
        onApplyCrop(norm)
    }

    override func keyDown(with event: NSEvent) {
        if isCropping {
            if event.keyCode == 53 { // Esc
                cancelCropping()
                return
            } else if event.keyCode == 36 { // Return / Enter
                commitCropping()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        cropOverlay.frame = bounds
        if isCropping && (cropOverlay.cropRect.width == 0 || cropOverlay.cropRect.height == 0) {
            cropOverlay.resetToFull()
        }
        let iconSize: CGFloat = 22
        placeholderIcon.frame = NSRect(x: (bounds.width - iconSize) / 2,
                                       y: (bounds.height - iconSize) / 2,
                                       width: iconSize, height: iconSize)
        let side = ImageGripView.side
        for (pos, grip) in grips {
            let center = pos.center(in: bounds)
            grip.frame = NSRect(x: center.x - side / 2, y: center.y - side / 2,
                                width: side, height: side)
        }
        sizeBadge.sizeToFit()
        let badgeWidth = sizeBadge.frame.width + 12
        sizeBadge.frame = NSRect(x: (bounds.width - badgeWidth) / 2, y: 8,
                                 width: badgeWidth, height: 15)

        // Toolbar: centered below the image (or nested inside if tight)
        let barW: CGFloat = isCropping ? 260 : 190
        let barH: CGFloat = 28
        let barX = max(0, (bounds.width - barW) / 2)
        let barY = bounds.height + 8
        toolbar.frame = NSRect(x: barX, y: barY, width: barW, height: barH)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The point arrives in the superview's (the text view's) coordinate
        // system; every frame compared below is local. Missing this conversion
        // once made any overlay away from the text origin unclickable.
        let local = convert(point, from: superview)
        if isCropping {
            if !toolbar.isHidden, toolbar.frame.contains(local) {
                return toolbar.hitTest(local) ?? toolbar
            }
            if bounds.contains(local) {
                return cropOverlay
            }
            return nil
        }
        if isSelected {
            if !toolbar.isHidden, toolbar.frame.contains(local) {
                // toolbar.hitTest wants the point in OUR coordinates — the
                // toolbar's superview — so `local` goes in unconverted.
                return toolbar.hitTest(local) ?? toolbar
            }
            for grip in grips.values where !grip.isHidden && grip is ImageResizeHandle {
                if grip.frame.insetBy(dx: -4, dy: -4).contains(local) {
                    return grip
                }
            }
        }
        let hitRect = isSelected
            ? bounds.insetBy(dx: -ImageGripView.side, dy: -ImageGripView.side)
                .union(toolbar.isHidden ? bounds : toolbar.frame)
            : bounds
        return hitRect.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect(self)
        let menu = NSMenu()

        let freeItem = NSMenuItem(title: "自由裁切 (内部选框)", action: #selector(handleMenuFreeCrop), keyEquivalent: "")
        freeItem.target = self
        menu.addItem(freeItem)

        let cropSubmenu = NSMenu()
        let ratios: [(String, CGFloat)] = [
            ("1:1 (正方形)", 1.0),
            ("4:3 (标准横屏)", 4.0 / 3.0),
            ("16:9 (宽屏)", 16.0 / 9.0),
            ("3:4 (标准竖屏)", 3.0 / 4.0),
            ("9:16 (手机竖屏)", 9.0 / 16.0)
        ]
        for (title, r) in ratios {
            let item = NSMenuItem(title: title, action: #selector(handleMenuCrop(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            cropSubmenu.addItem(item)
        }
        let cropItem = NSMenuItem(title: "裁切比例 (锁定比例框)", action: nil, keyEquivalent: "")
        cropItem.submenu = cropSubmenu
        menu.addItem(cropItem)

        menu.addItem(.separator())

        let widthSubmenu = NSMenu()
        let widths: [(String, CGFloat)] = [
            ("100% (满宽)", 1.0),
            ("75%", 0.75),
            ("50%", 0.5)
        ]
        for (title, w) in widths {
            let item = NSMenuItem(title: title, action: #selector(handleMenuWidth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = w
            widthSubmenu.addItem(item)
        }
        let widthItem = NSMenuItem(title: "宽度比例", action: nil, keyEquivalent: "")
        widthItem.submenu = widthSubmenu
        menu.addItem(widthItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "复制图片", action: #selector(handleMenuCopy), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        return menu
    }

    @objc private func handleMenuCopy() { onCopy() }
    @objc private func handleMenuFreeCrop() { startCropping(ratio: nil) }
    @objc private func handleMenuCrop(_ item: NSMenuItem) {
        if let r = item.representedObject as? CGFloat { startCropping(ratio: r) }
    }
    @objc private func handleMenuWidth(_ item: NSMenuItem) {
        if let w = item.representedObject as? CGFloat { onSetWidthFraction(w) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !hasFile {
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
            let haloRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let halo = NSBezierPath(rect: haloRect)
            halo.lineWidth = 3
            NSColor.white.withAlphaComponent(0.6).setStroke()
            halo.stroke()
        }
        if isSelected || isHovering {
            let line = NSBezierPath(rect: bounds.insetBy(dx: 0.75, dy: 0.75))
            line.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            line.stroke()
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
    private var resizingKey: String?
    private var isHandlingAction = false
    /// Caret location parked by `select`. The selection frame survives while
    /// the caret stays there; any real edit or click moves it and deselects.
    private var parkedCaret: Int?

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
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                            object: textView, queue: .main) { [weak self] _ in
            self?.selectionDidChange()
        })
    }

    /// Clicking or typing anywhere but the parked caret drops the frame, so a
    /// selected image never keeps its chrome after focus has moved on.
    private func selectionDidChange() {
        guard let tv = textView else { return }
        if isHandlingAction { return }
        if let parked = parkedCaret,
           tv.selectedRange() == NSRange(location: parked, length: 0) { return }
        parkedCaret = nil
        for (_, overlay) in overlays { overlay.setSelected(false) }
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
        resizingKey = finished ? nil : key
        let cap = tv.textContainer?.size.width ?? slot.width
        let width = min(max(NoteImageMetrics.minWidth,
                            point.x - overlay.frame.minX), max(NoteImageMetrics.minWidth, cap))
        guard abs(width - slot.width) > 0.25, slot.height > 0 else {
            if finished {
                resizingKey = nil
                overlay.hideSize()
            }
            return
        }
        let height = width * slot.height / slot.width
        slot.width = width
        slot.height = height
        slots[key] = slot
        overlay.frame.size = NSSize(width: width, height: height)

        if !finished {
            overlay.showSize(width: width, height: height)
            layoutDelegate.heights = layoutDelegate.heights.map {
                $0.range == slot.tokenRange
                    ? (range: $0.range, height: height, width: width) : $0
            }
            tv.layoutManager?.invalidateLayout(forCharacterRange: slot.tokenRange,
                                               actualCharacterRange: nil)
            return
        }
        resizingKey = nil
        overlay.hideSize()
        commitWidth(width, for: slot, in: tv, storage: storage)
    }

    /// Rewrite the token's width field as one undoable edit. The token carries
    /// its own size, so a resize survives restarts and rides through export.
    private func commitWidth(_ width: CGFloat, for slot: Slot,
                             in tv: TaskTextView, storage: NSTextStorage) {
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

    // MARK: - Actions (Copy, Crop, Reset, Width)

    private func copyImage(id: String) {
        guard let image = ImageStore.image(id: id) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func applyCrop(key: String, normalizedRect: NSRect) {
        isHandlingAction = true
        defer { isHandlingAction = false }
        guard let slot = slots[key], let tv = textView, let storage = tv.textStorage else { return }
        guard let newID = ImageStore.crop(id: slot.id, normalizedRect: normalizedRect) else { return }
        let tokens = ImageStore.tokens(in: storage.string)
        guard let token = tokens.filter({ $0.id == slot.id })
            .min(by: { abs($0.range.location - slot.tokenRange.location)
                        < abs($1.range.location - slot.tokenRange.location) }) else { return }
        let newWidth = max(NoteImageMetrics.minWidth, (slot.width * normalizedRect.width).rounded())
        let replacement = ImageStore.token(id: newID, width: newWidth)
        guard tv.shouldChangeText(in: token.range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: token.range, with: replacement)
        tv.didChangeText()
        refresh()
    }

    private func setWidthFraction(key: String, fraction: CGFloat) {
        isHandlingAction = true
        defer { isHandlingAction = false }
        guard let slot = slots[key], let tv = textView, let storage = tv.textStorage else { return }
        let containerWidth = tv.textContainer?.size.width ?? NoteImageMetrics.defaultMaxWidth
        let targetWidth = max(NoteImageMetrics.minWidth, (containerWidth * fraction).rounded())
        let tokens = ImageStore.tokens(in: storage.string)
        guard let token = tokens.filter({ $0.id == slot.id })
            .min(by: { abs($0.range.location - slot.tokenRange.location)
                        < abs($1.range.location - slot.tokenRange.location) }) else { return }
        let replacement = ImageStore.token(id: token.id, width: targetWidth)
        guard tv.shouldChangeText(in: token.range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: token.range, with: replacement)
        tv.didChangeText()
        refresh()
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
            if overlay.isSelected { parkedCaret = nil }
            overlay.removeFromSuperview()
            overlays.removeValue(forKey: key)
            slots.removeValue(forKey: key)
        }
        for (key, info) in wanted {
            slots[key] = info.slot
            if let overlay = overlays[key] {
                if key != resizingKey {
                    overlay.frame = info.frame
                }
            } else {
                let overlay = NoteImageOverlayView(imageID: info.slot.id,
                                                   image: info.slot.hasFile
                                                       ? ImageStore.image(id: info.slot.id) : nil)
                overlay.frame = info.frame
                overlay.onSelect = { [weak self] picked in self?.select(picked) }
                overlay.onDrag = { [weak self] point, finished in
                    self?.handleDrag(key, point: point, finished: finished)
                }
                overlay.onCopy = { [weak self] in self?.copyImage(id: info.slot.id) }
                overlay.onApplyCrop = { [weak self] norm in self?.applyCrop(key: key, normalizedRect: norm) }
                overlay.onSetWidthFraction = { [weak self] f in self?.setWidthFraction(key: key, fraction: f) }
                tv.addSubview(overlay)
                overlays[key] = overlay
            }
        }
    }

    private func select(_ picked: NoteImageOverlayView) {
        for (_, overlay) in overlays {
            overlay.setSelected(overlay === picked)
        }
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
        parkedCaret = caret
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        tv.window?.makeFirstResponder(tv)
    }

    private func removeAll() {
        for (_, overlay) in overlays { overlay.removeFromSuperview() }
        overlays.removeAll()
        slots.removeAll()
        layoutDelegate.heights = []
        parkedCaret = nil
    }
}

