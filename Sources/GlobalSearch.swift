import AppKit
import Combine

struct GlobalSearchResults {
    private(set) var query = ""
    private(set) var notes: [Note] = []
    var selectedIndex = -1
    var selected: Note? { notes.indices.contains(selectedIndex) ? notes[selectedIndex] : nil }

    mutating func update(query: String, notes: [Note]) {
        let previousID = query == self.query ? selected?.id : nil
        self.query = query
        self.notes = NoteQuery(text: query, sort: .modified).results(in: notes)
        selectedIndex = previousID.flatMap { id in self.notes.firstIndex { $0.id == id } }
            ?? (self.notes.isEmpty ? -1 : 0)
    }

    mutating func move(_ delta: Int) {
        guard !notes.isEmpty else { selectedIndex = -1; return }
        selectedIndex = min(notes.count - 1, max(0, selectedIndex + delta))
    }

    /// Show context around a body match, including matches far down a long note.
    /// Neither persisted formatting wrappers nor image URLs belong in results.
    static func snippet(for note: Note, query: String) -> String {
        let text = Note.strippingImageTokens(NoteFormatting.plainText(note.body))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let match = query.split(whereSeparator: \.isWhitespace).compactMap {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min()
        let start = match.map { text.index($0, offsetBy: -28, limitedBy: text.startIndex) ?? text.startIndex }
            ?? text.startIndex
        let end = text.index(start, offsetBy: 130, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}

/// Search takes keyboard focus without switching away from the user's current
/// app. Opening a result then hands focus to that note's independent window.
final class GlobalSearch: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = GlobalSearch()
    private var panel: SearchPanel?
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private var results = GlobalSearchResults()
    private var observer: AnyCancellable?
    private var shownAt = Date.distantPast

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
            return
        }
        if panel == nil { buildPanel() }
        guard let panel else { return }
        field.stringValue = ""
        results = GlobalSearchResults()
        observer = NoteStore.shared.$notes.sink { [weak self] notes in
            self?.refresh(notes)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.minY + (frame.height - panel.frame.height) * 0.65))
        }
        shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        observer = nil
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Ignore focus bounces during the global hotkey release and transfers
        // to the Chinese input-method/emoji helper.
        if Date().timeIntervalSince(shownAt) < 0.35 || EditorInputPanels.isVisible { return }
        dismiss()
    }

    private func buildPanel() {
        let p = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 490),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.title = L10n.text("search.title")
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.delegate = self

        let root = NSVisualEffectView()
        root.material = .popover
        root.state = .active
        p.contentView = root
        let title = NSTextField(labelWithString: "Noty · " + L10n.text("search.title"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        field.placeholderString = L10n.text("search.placeholder")
        field.setAccessibilityLabel(L10n.text("search.title"))
        field.font = .systemFont(ofSize: 20)
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 78
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openClickedResult)
        table.setAccessibilityLabel(L10n.text("search.results"))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: L10n.text("search.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        for view in [title, field, scroll, status, hint, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            field.heightAnchor.constraint(equalToConstant: 36),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        panel = p
    }

    private func refresh(_ notes: [Note]) {
        results.update(query: field.stringValue, notes: notes)
        table.reloadData()
        selectCurrentRow()
        status.stringValue = results.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("search.recent") : L10n.format("search.count", results.notes.count)
        empty.stringValue = L10n.text(results.query.isEmpty ? "search.empty" : "library.no_matches")
        empty.isHidden = !results.notes.isEmpty
    }

    private func selectCurrentRow() {
        if results.selectedIndex >= 0 {
            table.selectRowIndexes(IndexSet(integer: results.selectedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(results.selectedIndex)
        } else { table.deselectAll(nil) }
    }

    func controlTextDidChange(_ obj: Notification) { refresh(NoteStore.shared.notes) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): results.move(1); selectCurrentRow()
        case #selector(NSResponder.moveUp(_:)): results.move(-1); selectCurrentRow()
        case #selector(NSResponder.insertNewline(_:)): openSelectedResult()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    @objc private func openClickedResult() {
        guard results.notes.indices.contains(table.clickedRow) else { return }
        results.selectedIndex = table.clickedRow
        openSelectedResult()
    }

    private func openSelectedResult() {
        guard let id = results.selected?.id,
              let note = NoteStore.shared.note(id: id), !note.isTrashed else {
            refresh(NoteStore.shared.notes)
            return
        }
        dismiss()
        FloatingNotes.shared.open(ids: [id])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = results.notes[row]
        let identifier = NSUserInterfaceItemIdentifier("result")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCell) ?? SearchResultCell()
        cell.identifier = identifier
        cell.title.stringValue = note.displayTitle
        cell.snippet.stringValue = GlobalSearchResults.snippet(for: note, query: results.query)
        cell.metadata.stringValue = ([note.archived ? L10n.text("menu.archive") : nil,
                                      note.project.isEmpty ? nil : note.project]
            .compactMap { $0 } + note.tags.map { "#" + $0 }).joined(separator: " · ")
        return cell
    }
}

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SearchResultCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let snippet = NSTextField(labelWithString: "")
    let metadata = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        snippet.font = .systemFont(ofSize: 12)
        snippet.textColor = .secondaryLabelColor
        metadata.font = .systemFont(ofSize: 10)
        metadata.textColor = .secondaryLabelColor
        textField = title
        let stack = NSStackView(views: [title, snippet, metadata])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for label in [title, snippet, metadata] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
