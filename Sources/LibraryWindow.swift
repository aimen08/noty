import AppKit
import SwiftUI
import Combine

enum LibraryMode: String, CaseIterable, Identifiable {
    case all = "All Notes"
    case archive = "Archive"
    var id: String { rawValue }
}

final class LibraryModel: ObservableObject {
    @Published var mode: LibraryMode = .all
    @Published var query = ""
    @Published var selection: String?
    let bridge = EditorBridge()
}

/// "⌥⌘A opens every note in one window" — plus the archive, on ⌥⌘L.
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let model = LibraryModel()

    var isOpen: Bool { window?.isVisible ?? false }

    func show(mode: LibraryMode) {
        model.mode = mode
        if model.selection == nil { model.selection = currentList().first?.id }

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Noty")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 720, height: 420)
            w.delegate = self
            w.contentView = NSHostingView(rootView: LibraryView(model: model))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func currentList() -> [Note] {
        model.mode == .all ? NoteStore.shared.active : NoteStore.shared.archived
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-less agent so the dock icon disappears again —
        // unless Settings is still up.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - View

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var store = NoteStore.shared

    private var source: [Note] { model.mode == .all ? store.active : store.archived }

    private var filtered: [Note] {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return source }
        return source.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    private var selected: Note? {
        guard let id = model.selection else { return nil }
        return store.note(id: id)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
                .background(.regularMaterial)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 420)
        .onChange(of: model.mode) { _, _ in
            model.selection = filtered.first?.id
        }
        .onAppear {
            if model.selection == nil || store.note(id: model.selection!) == nil {
                model.selection = filtered.first?.id
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.mode) {
                ForEach(LibraryMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 34)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search all notes", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.mode == .all ? "note.text" : "archivebox")
                        .font(.system(size: 22)).foregroundStyle(.quaternary)
                    Text(model.query.isEmpty
                         ? (model.mode == .all ? "No notes yet" : "Nothing archived")
                         : "No matches")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $model.selection) { note in
                    row(note).tag(note.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider()
            HStack(spacing: 12) {
                Button { NoteStore.shared.create() } label: {
                    Label("New Note", systemImage: "plus").font(.system(size: 11.5))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)

                Menu {
                    Button("Markdown — one file per note…") {
                        Transfer.export(.markdown, notes: NoteStore.shared.notes)
                    }
                    Button("Plain text — one file per note…") {
                        Transfer.export(.plainText, notes: NoteStore.shared.notes)
                    }
                    Button("Single document…") {
                        Transfer.export(.singleFile, notes: NoteStore.shared.notes)
                    }
                    Button("Sticky archive (.stickies)…") {
                        Transfer.export(.stickies, notes: NoteStore.shared.notes)
                    }
                    Divider()
                    Button("Import…") { Transfer.importFiles() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .fixedSize()

                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
    }

    private func row(_ note: Note) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(note.palette.dash)
                .frame(width: 3.5, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(Fmt.ago(note.modified))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let p = note.taskProgress {
                        Label("\(p.done)/\(p.total)",
                              systemImage: p.done == p.total ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 9.5))
                            .foregroundStyle(p.done == p.total ? Color.green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if !note.preview.isEmpty {
                        Text(note.preview)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if note.archived {
                Button("Restore") { NoteStore.shared.setArchived(id: note.id, false) }
            } else {
                Button("Archive") { NoteStore.shared.setArchived(id: note.id, true) }
            }
            Divider()
            Button("Delete") { NoteStore.shared.delete(id: note.id) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = selected {
            LibraryDetail(note: note, bridge: model.bridge)
                .id(note.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right").font(.system(size: 26)).foregroundStyle(.quaternary)
                Text("Select a note").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Detail pane

struct LibraryDetail: View {
    let note: Note
    let bridge: EditorBridge

    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?

    private var pal: NoteColor { note.palette }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { NoteStore.shared.cycleColor(id: note.id) } label: {
                    Circle().fill(pal.dash).frame(width: 12, height: 12)
                        .padding(3).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Cycle colour · right-click to pick")
                .contextMenu {
                    ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                        Button(idx == note.color ? "✓ \(c.name)" : c.name) {
                            NoteStore.shared.setColor(id: note.id, color: idx)
                        }
                    }
                }

                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("Edited \(Fmt.ago(note.modified))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)

                NoteTextDirectionMenu(direction: note.textDirection,
                                      foreground: .secondary) {
                    NoteStore.shared.setTextDirection(id: note.id, direction: $0)
                }

                if note.archived {
                    Button("Restore") { NoteStore.shared.setArchived(id: note.id, false) }
                        .controlSize(.small)
                } else {
                    Button("Archive") { NoteStore.shared.setArchived(id: note.id, true) }
                        .controlSize(.small)
                }
                Button {
                    NoteStore.shared.delete(id: note.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 10)
            .background(pal.dash.opacity(0.12))

            NoteTextView(text: $text, ink: NSColor(pal.ink), bridge: bridge,
                         autofocus: false, fontSize: Settings.noteFontSize,
                         markdownEnabled: Settings.markdownStyling,
                         textDirection: note.textDirection,
                         styleToken: "\(note.color)|\(Settings.noteFontSize)|\(Settings.noteFontName)|\(Settings.markdownStyling)")
                .background(pal.paper)
        }
        .onAppear { text = note.body }
        .onChange(of: text) { _, v in
            saveWork?.cancel()
            let w = DispatchWorkItem { NoteStore.shared.updateBody(id: note.id, body: v) }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
        .onDisappear {
            saveWork?.cancel()
            NoteStore.shared.updateBody(id: note.id, body: text)
        }
    }
}
