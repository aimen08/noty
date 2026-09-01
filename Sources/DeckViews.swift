import SwiftUI

// MARK: - Root

struct DeckRootView: View {
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    @ObservedObject var store = NoteStore.shared

    private var onRight: Bool { !deck.onLeftEdge }
    private var edge: Edge { onRight ? .trailing : .leading }

    private var visible: [Note] {
        deck.showAll ? store.active : Array(store.active.prefix(Settings.fanLimit))
    }
    private var hiddenCount: Int { max(0, store.active.count - Settings.fanLimit) }
    private var showsMoreTab: Bool { !deck.showAll && hiddenCount > 0 }
    /// An empty deck still draws one tab, so the stack is never zero-height.
    private var itemCount: Int { max(1, visible.count) }

    /// Widest label currently on the deck — drives how tall each tab's strip is.
    private var longestLabel: CGFloat {
        visible.map { DeckGeom.labelWidth($0.displayTitle) }.max() ?? 0
    }

    private func layout(_ panelHeight: CGFloat) -> DeckLayout {
        DeckGeom.layout(panelHeight: panelHeight, count: itemCount,
                        hasMore: showsMoreTab, style: deck.style,
                        longestLabel: longestLabel)
    }

    var body: some View {
        // The height comes from the live layout pass, not from a value cached on
        // the model. When the panel resizes, AppKit relays out the existing view
        // tree at the new size *before* SwiftUI re-evaluates this body; anything
        // computed from a stored height is stale for that frame, and the pill
        // drew with zero padding at the top corner of the screen.
        GeometryReader { geo in
            let h = max(1, geo.size.height)
            let lay = layout(h)

            ZStack(alignment: onRight ? .topTrailing : .topLeading) {

                if deck.fanVisible || h > lay.stackHeight {
                    FanColumn(deck: deck, controller: controller,
                              notes: visible, hiddenCount: showsMoreTab ? hiddenCount : 0,
                              layout: lay, onRight: onRight)
                        .padding(.top, fanTop(lay, panelHeight: h))
                }

                PillView(notes: store.active)
                    .padding(.top, pillTop(panelHeight: h))
                    .padding(onRight ? .trailing : .leading, 1)
                    .opacity(deck.state == .rest ? 1 : 0)
                    .animation(.easeInOut(duration: 0.20).delay(deck.state == .rest ? 0.12 : 0), value: deck.state)

                // Declared last so it covers the deck, flush to the screen edge.
                if let id = deck.state.expandedID, let note = store.note(id: id) {
                    NoteEditorView(note: note, deck: deck, controller: controller, onRight: onRight)
                        .padding(.top, editorTop(lay, id: id))
                        .transition(.modifier(
                            active: NotePull(hidden: true, onRight: onRight),
                            identity: NotePull(hidden: false, onRight: onRight)))
                        .id(id)
                }
            }
            // A ZStack is only as wide as its widest child, so it has to be told to fill
            // the panel — otherwise the deck sits at the panel's left edge with a dead
            // gap against the screen. Filling from the parent's proposal (rather than a
            // measured width) keeps it pinned to the edge through a resize.
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: onRight ? .topTrailing : .topLeading)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.9), value: deck.fanVisible)
        .animation(.easeInOut(duration: 0.22), value: deck.style)
    }

    /// Where the pill sits, for any panel height. At rest the panel is exactly the
    /// pill's height and this is zero; in a full-height panel it lands on the same
    /// screen position the resting panel occupies, so the pill does not move as the
    /// panel grows around it or shrinks back to it.
    private func pillTop(panelHeight h: CGFloat) -> CGFloat {
        let pillH = DeckGeom.pillHeight(noteCount: max(1, store.active.count))
        return (1.0 - Settings.deckYRatio) * max(0, h - pillH)
    }

    private func fanTop(_ lay: DeckLayout, panelHeight h: CGFloat) -> CGFloat {
        let pillH = DeckGeom.pillHeight(noteCount: max(1, store.active.count))
        let availableH = max(1, h - pillH)
        let pillCenter = (1.0 - Settings.deckYRatio) * availableH + pillH / 2
        let ideal = pillCenter - lay.stackHeight / 2
        return min(max(12, ideal), max(12, h - lay.stackHeight - 12))
    }

    /// Keep the open note level with its own tab, without letting it run off-screen.
    private func editorTop(_ lay: DeckLayout, id: String) -> CGFloat {
        if let top = deck.openedTop { return top }
        let idx = visible.firstIndex { $0.id == id } ?? 0
        let h = deck.openedHeight
        let fTop = fanTop(lay, panelHeight: lay.panelHeight)
        let strip = idx == lay.count - 1 ? lay.itemHeight : lay.pitch
        let stripCenter = fTop + CGFloat(idx) * lay.pitch + strip / 2
        let ideal = stripCenter - h / 2
        let lowest = max(10, lay.panelHeight - h - 10)
        let resolved = min(max(10, ideal), lowest)
        DispatchQueue.main.async { deck.openedTop = resolved }
        return resolved
    }
}

// MARK: - Pill (at rest)

struct PillView: View {
    let notes: [Note]

    private var shown: [Note] { Array(notes.prefix(DeckGeom.maxDashes)) }
    private var overflow: Int { max(0, notes.count - DeckGeom.maxDashes) }

    var body: some View {
        VStack(spacing: DeckGeom.dashGap) {
            if notes.isEmpty { dash(Color.secondary.opacity(0.4)) }
            ForEach(shown) { dash($0.palette.dash) }
            if overflow > 0 { dash(Color.secondary.opacity(0.5)) }
        }
        .padding(.vertical, DeckGeom.pillPad)
        .frame(width: DeckGeom.pillWidth)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 6, x: -2, y: 1)
        )
    }

    private func dash(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(color)
            .frame(width: DeckGeom.dashWidth, height: DeckGeom.dashHeight)
    }
}

// MARK: - Fan

struct FanColumn: View {
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    let notes: [Note]
    let hiddenCount: Int
    let layout: DeckLayout
    let onRight: Bool

    @State private var appeared = false
    @State private var hoverWork: DispatchWorkItem?
    @State private var previewWork: DispatchWorkItem?
    @State private var previewNoteID: String?
    @State private var dragID: String?
    @State private var dragTarget: Int = 0

    private var isRevealed: Bool {
        deck.state != .rest && appeared
    }

    private var activePreviewNote: Note? {
        guard let id = previewNoteID, dragID == nil, deck.state.expandedID == nil else { return nil }
        return notes.first { $0.id == id }
    }

    private var previewIndex: Int {
        guard let id = previewNoteID, let idx = notes.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    var body: some View {
        ZStack(alignment: onRight ? .topTrailing : .topLeading) {
            Group {
                if deck.showAll && layout.overflows {
                    ScrollView(.vertical, showsIndicators: false) {
                        stack.padding(.vertical, 4)
                    }
                    .frame(height: layout.cap)
                    .scrollClipDisabled()
                } else {
                    stack
                }
            }
            .overlay(alignment: onRight ? .trailing : .leading) { spine }

            if let previewNote = activePreviewNote {
                NotePreviewCard(note: previewNote, onRight: onRight, onHoverChanged: { inside in
                    if inside {
                        previewWork?.cancel()
                    } else {
                        cancelHoverPreview(for: previewNote.id)
                    }
                }) {
                    previewNoteID = nil
                    open(previewNote)
                }
                .padding(.top, CGFloat(previewIndex) * layout.pitch)
                .padding(onRight ? .trailing : .leading, DeckGeom.tabWidth + 10)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: onRight ? 10 : -10)),
                    removal: .opacity
                ))
            }
        }
        .onAppear {
            DispatchQueue.main.async { appeared = true }
        }
        .onChange(of: deck.revealTick) { _, _ in
            appeared = false
            previewNoteID = nil
            DispatchQueue.main.async { appeared = true }
        }
        .onChange(of: deck.state) { _, newState in
            if newState == .rest {
                appeared = false
                previewNoteID = nil
                cancelHoverPreview()
            }
        }
    }

    /// The lap comes from negative stack spacing — real layout, so hit areas follow
    /// the tabs. (`.offset` would draw them in the right place but leave their taps
    /// behind at the top of the stack.) Paint order is left to declaration order: a
    /// stack draws later children on top, which is exactly the lap we want. An
    /// explicit `zIndex` per tab is *not* equivalent — it reorders neighbours and
    /// breaks the shingle.
    private var stack: some View {
        let total = notes.count + (hiddenCount > 0 ? 1 : 0) + 2
        return VStack(spacing: layout.spacing) {
            if notes.isEmpty {
                EmptyTab(height: layout.itemHeight, strip: layout.pitch, onRight: onRight) {
                    (NSApp.delegate as? AppDelegate)?.newNote()
                }
                .staged(index: 0, total: 3, revealed: isRevealed, onRight: onRight)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                Group {
                    if deck.style == .compact {
                        ChipTab(note: note,
                                isOpen: deck.state.expandedID == note.id,
                                onRight: onRight,
                                action: { open(note) },
                                onHoverChanged: { inside in
                                    handleHover(note: note, inside: inside)
                                })
                    } else {
                        VerticalTab(note: note,
                                    isOpen: deck.state.expandedID == note.id,
                                    height: layout.itemHeight,
                                    strip: layout.pitch,
                                    onRight: onRight,
                                    lifted: dragID == note.id,
                                    action: { open(note) },
                                    onDragChanged: { dy in
                                        if dragID != note.id {
                                            dragID = note.id
                                            dragTarget = idx
                                            deck.isDragging = true
                                            cancelHoverOpen()
                                            cancelHoverPreview()
                                        }
                                        // Assign only on a real slot change, so the
                                        // column redraws a handful of times per drag
                                        // rather than on every pointer move.
                                        let next = target(from: idx, dy: dy)
                                        if next != dragTarget { dragTarget = next }
                                    },
                                    onHoverChanged: { inside in
                                        handleHover(note: note, inside: inside)
                                    },
                                    onDragEnded: { dy in
                                        let to = target(from: idx, dy: dy)
                                        dragID = nil
                                        deck.isDragging = false
                                        if to != idx { NoteStore.shared.reorder(id: note.id, by: to - idx) }
                                    })
                    }
                }
                // Only the tabs stepping aside animate; the dragged one carries its
                // own un-animated offset.
                .offset(y: shift(idx))
                .animation(dragID == note.id ? nil
                           : .spring(response: 0.26, dampingFraction: 0.86), value: dragTarget)
                // Only the tab being dragged is raised. Giving *every* tab a
                // zIndex reorders neighbours and breaks the shingle; leaving the
                // rest at the default keeps their declaration order intact.
                .zIndex(dragID == note.id ? 900 : 0)
                .staged(index: idx, total: total, revealed: isRevealed, onRight: onRight)
            }
            if hiddenCount > 0 {
                MoreTab(count: hiddenCount, height: layout.moreHeight, onRight: onRight) {
                    deck.showAll = true
                }
                .padding(.top, layout.moreGap - layout.spacing)   // undo the lap
                .staged(index: notes.count, total: total, revealed: isRevealed, onRight: onRight)
            }
            PlusButton { (NSApp.delegate as? AppDelegate)?.newNote() }
                .padding(.top, DeckGeom.plusGap - layout.spacing)
                .staged(index: notes.count + (hiddenCount > 0 ? 1 : 0), total: total, revealed: isRevealed, onRight: onRight)
            CogButton { (NSApp.delegate as? AppDelegate)?.openSettings() }
                .padding(.top, DeckGeom.cogGap - layout.spacing)
                .staged(index: notes.count + (hiddenCount > 0 ? 1 : 0) + 1, total: total, revealed: isRevealed, onRight: onRight)
        }
        .frame(width: DeckGeom.tabWidth)
    }

    private func handleHover(note: Note, inside: Bool) {
        guard dragID == nil, deck.state.expandedID == nil else {
            cancelHoverOpen()
            cancelHoverPreview()
            return
        }
        if inside {
            // Hover-to-open makes the preview pointless — the note itself is
            // about to appear — so it wins and the card is skipped entirely.
            if deck.openOnHover { scheduleHoverOpen(note.id) }
            else if deck.tabPreview { scheduleHoverPreview(note) }
        } else {
            cancelHoverOpen()
            cancelHoverPreview(for: note.id)
        }
    }

    /// The pointer has to rest on a tab before it opens, or sweeping across the
    /// deck opens every note on the way past.
    private func scheduleHoverOpen(_ id: String) {
        hoverWork?.cancel()
        let work = DispatchWorkItem {
            guard deck.openOnHover, dragID == nil, deck.state.expandedID != id else { return }
            previewNoteID = nil
            controller.expand(id)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.openOnHoverDelay, execute: work)
    }

    private func cancelHoverOpen() { hoverWork?.cancel(); hoverWork = nil }

    private func scheduleHoverPreview(_ note: Note) {
        previewWork?.cancel()
        if previewNoteID != nil, previewNoteID != note.id {
            withAnimation(.easeOut(duration: 0.10)) {
                previewNoteID = nil
            }
        }
        let work = DispatchWorkItem {
            guard dragID == nil, deck.state.expandedID == nil, deck.tabPreview,
                  !deck.openOnHover else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                previewNoteID = note.id
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.tabPreviewDelay, execute: work)
    }

    private func cancelHoverPreview(for id: String? = nil) {
        previewWork?.cancel()
        let work = DispatchWorkItem {
            if id == nil || previewNoteID == id {
                withAnimation(.easeOut(duration: 0.12)) {
                    previewNoteID = nil
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var dragFrom: Int? { notes.firstIndex { $0.id == dragID } }

    /// Which slot the tab would drop into. A tab has to travel 60% of a slot
    /// before the target moves, not 50% — at the halfway mark the smallest
    /// pointer jitter flips the answer back and forth every frame, and each flip
    /// animates a whole row of tabs. That oscillation is the flashing.
    private func target(from: Int, dy: CGFloat) -> Int {
        let pitch = max(1, layout.pitch)
        let raw = dy / pitch
        let slots = raw > 0 ? Int(floor(raw + 0.4)) : Int(ceil(raw - 0.4))
        return min(max(0, from + slots), notes.count - 1)
    }

    /// The other tabs step aside as the dragged one passes, so the gap you are
    /// dropping into is always visible.
    private func shift(_ index: Int) -> CGFloat {
        guard let from = dragFrom, index != from else { return 0 }
        let to = dragTarget
        if from < to, index > from, index <= to { return -layout.pitch }
        if from > to, index < from, index >= to { return layout.pitch }
        return 0
    }

    private func open(_ note: Note) {
        if deck.state.expandedID == note.id { controller.collapse() }
        else { controller.expand(note.id) }
    }

    /// The dashed rule the deck hangs from, right at the screen edge.
    private var spine: some View {
        EdgeLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(width: 1, height: min(layout.stackHeight + 26, layout.cap))
            .padding(onRight ? .trailing : .leading, 3)
            .allowsHitTesting(false)
    }
}

/// The note emerging from its tab: a short slide off the edge, a touch of scale
/// anchored there, and a fade. A full-width slide reads as a window flying in.
struct NotePull: ViewModifier {
    let hidden: Bool
    let onRight: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: hidden ? (onRight ? 40 : -40) : 0)
            .scaleEffect(hidden ? 0.965 : 1, anchor: onRight ? .trailing : .leading)
            .opacity(hidden ? 0 : 1)
    }
}

struct EdgeLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

/// Rounded on the outward-facing side only, so the tab reads as docked to the edge.
func edgeTabShape(onRight: Bool, radius r: CGFloat = 11) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: onRight ? r : 0,
        bottomLeadingRadius: onRight ? r : 0,
        bottomTrailingRadius: onRight ? 0 : r,
        topTrailingRadius: onRight ? 0 : r,
        style: .continuous)
}

// MARK: - Tabs

/// A tab keeps its colour and carries its label turned on its side.
///
/// Tabs overlap, so the label is pinned to the top of the tab — the part that
/// stays uncovered. Hovering lifts the whole tab clear to reveal the rest of it.
struct VerticalTab: View {
    let note: Note
    let isOpen: Bool
    let height: CGFloat
    let strip: CGFloat          // the part of this tab the next one does not cover
    let onRight: Bool
    var lifted: Bool = false
    let action: () -> Void
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onDragEnded: (CGFloat) -> Void = { _ in }

    @State private var hovering = false
    @State private var dragging = false
    /// Held here rather than on the column: the dragged tab has to follow the
    /// pointer every frame, and keeping that state local means one small view
    /// redraws instead of every tab, its shadow and its material.
    @State private var dy: CGFloat = 0

    /// Past this much vertical travel it is a reorder, not a tap.
    private static let slop: CGFloat = 5

    /// One gesture, not a tap competing with a long-press. A press that never
    /// travels is a tap; anything that travels is a drag — and once it is a drag
    /// the tap can no longer fire, so dragging a tab cannot also open its note.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !dragging, abs(v.translation.height) > Self.slop { dragging = true }
                guard dragging else { return }
                dy = v.translation.height
                onDragChanged(dy)          // the column only reacts if the slot changed
            }
            .onEnded { v in
                if dragging {
                    onDragEnded(v.translation.height)
                } else if abs(v.translation.height) <= Self.slop {
                    action()
                }
                dragging = false
                dy = 0
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            edgeTabShape(onRight: onRight)
                .fill(note.palette.paper)
                .shadow(color: .black.opacity(lifted ? 0.42 : (isOpen || hovering ? 0.32 : 0.22)),
                        radius: lifted ? 16 : (isOpen || hovering ? 9 : 6),
                        x: onRight ? -3 : 3, y: lifted ? 6 : 2)
            Text(note.displayTitle.uppercased())
                .font(Ink.tabFont)
                .tracking(Ink.tabTracking)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(note.palette.ink.opacity(0.85))
                .frame(width: max(20, strip - DeckGeom.labelInset),
                       height: DeckGeom.tabWidth)
                .rotationEffect(.degrees(onRight ? 90 : -90))
                .frame(width: DeckGeom.tabWidth, height: strip)
                .offset(x: onRight ? -DeckGeom.bleed / 2 : DeckGeom.bleed / 2)
        }
        .frame(width: DeckGeom.tabWidth + DeckGeom.bleed, height: height, alignment: .top)
        .scaleEffect(lifted ? 1.04 : 1, anchor: onRight ? .trailing : .leading)
        .rotationEffect(.degrees(DeckGeom.lean(onRight: onRight)), anchor: onRight ? .trailing : .leading)
        .offset(x: onRight ? DeckGeom.bleed : -DeckGeom.bleed)
        .frame(width: DeckGeom.tabWidth)
        // Deliberately not animated: the dragged tab must track the pointer
        // exactly. A spring here reads as lag.
        .offset(y: dy)
        .contentShape(Rectangle())
        .overlay(alignment: onRight ? .topTrailing : .topLeading) {
            if note.pinned {
                Circle()
                    .fill(note.palette.dash)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(onRight ? .trailing : .leading, 9)
            }
        }
        .gesture(press)
        .onHover { hovering = $0; onHoverChanged($0) }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOpen)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.spring(response: 0.26, dampingFraction: 0.75), value: lifted)
        .noteContextMenu(note)
        .help(note.displayTitle)
    }
}

/// Compact style — colour only, so the deck barely touches the screen.
struct ChipTab: View {
    let note: Note
    let isOpen: Bool
    let onRight: Bool
    let action: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) {
            edgeTabShape(onRight: onRight, radius: 7)
                .fill(note.palette.dash)
                .frame(width: DeckGeom.chipWidth, height: DeckGeom.chipHeight)
                .shadow(color: .black.opacity(isOpen ? 0.34 : 0.22), radius: isOpen ? 8 : 5,
                        x: onRight ? -2 : 2, y: 1)
                .rotationEffect(.degrees(DeckGeom.lean(onRight: onRight) * 0.6), anchor: onRight ? .trailing : .leading)
                .offset(x: onRight ? DeckGeom.bleed / 2 : -DeckGeom.bleed / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .animation(.spring(response: 0.26, dampingFraction: 0.8), value: isOpen)
        .onHover { onHoverChanged($0) }
        .noteContextMenu(note)
        .help(note.displayTitle)
    }
}

/// Flyout preview card showing a note's title, checklist progress, and body snippet on tab hover.
struct NotePreviewCard: View {
    let note: Note
    let onRight: Bool
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(note.palette.dash)
                        .frame(width: 7, height: 7)
                    Text(note.displayTitle)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(note.palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let prog = note.taskProgress {
                        Text("\(prog.done)/\(prog.total)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(note.palette.ink.opacity(0.65))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(note.palette.ink.opacity(0.12)))
                    }
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(note.palette.ink.opacity(0.7))
                    }
                }

                let lines = note.body.split(whereSeparator: \.isNewline).map(String.init)
                let previewLines = Array(lines.dropFirst().prefix(4))
                if !previewLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                            if Tasks.isTask(line) {
                                let isDone = Tasks.marker(of: line) == Tasks.done
                                HStack(spacing: 4) {
                                    // Done tasks dim in the note's own ink, exactly as the
                                    // editor draws them. Color.secondary follows the system
                                    // appearance, not the paper — near-white in dark mode.
                                    Image(systemName: isDone ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(note.palette.ink.opacity(isDone ? 0.45 : 0.75))
                                    Text(Tasks.stripped(line))
                                        .font(.system(size: 10.5))
                                        .strikethrough(isDone, color: note.palette.ink.opacity(0.45))
                                        .foregroundStyle(note.palette.ink.opacity(isDone ? 0.45 : 0.85))
                                        .lineLimit(1)
                                }
                            } else {
                                Text(line)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(note.palette.ink.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }
                    }
                } else if note.body.isEmpty || lines.count <= 1 {
                    Text("Empty note")
                        .font(.system(size: 10).italic())
                        .foregroundStyle(note.palette.ink.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(note.palette.paper)
                    .shadow(color: .black.opacity(0.26), radius: 9, x: onRight ? -3 : 3, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(note.palette.ink.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onHoverChanged?($0) }
    }
}

struct MoreTab: View {
    let count: Int
    let height: CGFloat
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                edgeTabShape(onRight: onRight, radius: 9)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 5, x: onRight ? -2 : 2, y: 1)
                Text("+\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: DeckGeom.tabWidth, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .help("\(count) more note\(count == 1 ? "" : "s")")
    }
}

struct EmptyTab: View {
    let height: CGFloat
    let strip: CGFloat
    let onRight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(onRight: onRight).fill(.ultraThinMaterial)
                Text("NEW NOTE")
                    .font(Ink.tabFont)
                    .tracking(Ink.tabTracking)
                    .foregroundStyle(.secondary)
                    .frame(width: max(20, strip - DeckGeom.labelInset),
                           height: DeckGeom.tabWidth)
                    .rotationEffect(.degrees(onRight ? 90 : -90))
                    .frame(width: DeckGeom.tabWidth, height: strip)
            }
            .frame(width: DeckGeom.tabWidth, height: height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
    }
}

struct PlusButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: DeckGeom.plusSize, height: DeckGeom.plusSize)
                .background(Circle().fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("New Note  ⌥⌘N")
    }
}

/// Settings, one step below the new-note button. The pill's context menu still
/// has everything; this is just the door people can find.
struct CogButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovering ? 0.8 : 0.5))
                .frame(width: DeckGeom.cogSize, height: DeckGeom.cogSize)
                .background(Circle().fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Settings  ⌘,")
    }
}

// MARK: - Shared bits

extension View {
    func noteContextMenu(_ note: Note) -> some View {
        contextMenu {
            Button(note.pinned ? "Unpin" : "Pin") { NoteStore.shared.togglePin(id: note.id) }
            Button("Archive") { NoteStore.shared.setArchived(id: note.id, true) }
            Button("Cycle colour  ⌘.") { NoteStore.shared.cycleColor(id: note.id) }
            Divider()
            Button("Delete") { NoteStore.shared.delete(id: note.id) }
        }
    }
}

// MARK: - Staging (the 45 ms shingle)

private struct Staged: ViewModifier {
    let index: Int
    let totalCount: Int
    let revealed: Bool
    let onRight: Bool

    func body(content: Content) -> some View {
        let delay = revealed
            ? Double(index) * 0.042
            : Double(max(0, totalCount - 1 - index)) * 0.030
        content
            .offset(x: revealed ? 0 : (onRight ? DeckGeom.tabWidth + 24 : -(DeckGeom.tabWidth + 24)))
            .opacity(revealed ? 1 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.84)
                        .delay(delay), value: revealed)
    }
}

private extension View {
    func staged(index: Int, total: Int = 1, revealed: Bool, onRight: Bool) -> some View {
        modifier(Staged(index: index, totalCount: total, revealed: revealed, onRight: onRight))
    }
}

struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
