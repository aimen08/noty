import AppKit
import SwiftUI
import Combine

typealias LibraryMode = NoteScope

final class LibraryModel: ObservableObject {
    @Published var criteria = NoteQuery()
    @Published var selection = Set<String>()
    let bridge = EditorBridge()
}

final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    private var window: NSWindow?
    private let model = LibraryModel()
    var isOpen: Bool { window?.isVisible ?? false }

    func show(mode: LibraryMode) {
        model.criteria = NoteQuery(scope: mode)
        model.selection = []
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Noty"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 520)
            w.delegate = self
            w.contentView = NSHostingView(rootView: LibraryView(model: model))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.didClose(notification)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var store = NoteStore.shared
    @State private var organizing = false
    @State private var confirmingDeletion = false
    private var filtered: [Note] { model.criteria.results(in: store.notes) }
    private var selected: [Note] { filtered.filter { model.selection.contains($0.id) } }
    private var ids: Set<String> { Set(selected.map(\.id)) }
    private var inTrash: Bool { model.criteria.scope == .trash }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 330).background(.regularMaterial)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: filtered.map(\.id)) { _, visible in
            model.selection.formIntersection(visible)
        }
        .sheet(isPresented: $organizing) { OrganizationSheet(notes: selected) }
        .alert(L10n.text("organize.permanent_title"), isPresented: $confirmingDeletion) {
            Button(L10n.text("organize.permanent"), role: .destructive) {
                store.permanentlyDelete(ids: ids)
            }
            Button(L10n.text("organize.cancel"), role: .cancel) {}
        } message: { Text(L10n.text("organize.permanent_message")) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { let n = store.create(); model.criteria = NoteQuery(); model.selection = [n.id] } label: {
                Label(L10n.text("menu.new_note"), systemImage: "plus")
            }
            Button { NoteBoardWindow.shared.show(ids: (selected.isEmpty ? filtered : selected).map(\.id)) } label: {
                Label(L10n.text("organize.spread"), systemImage: "square.grid.2x2")
            }.disabled(inTrash || filtered.isEmpty)
            Spacer()
            if !selected.isEmpty {
                Text(L10n.format("organize.selected", selected.count)).foregroundStyle(.secondary)
                if inTrash {
                    Button(L10n.text("action.restore")) { store.restore(ids: ids) }
                    Button(L10n.text("organize.permanent"), role: .destructive) { confirmingDeletion = true }
                } else {
                    Button(L10n.text("organize.edit")) { organizing = true }
                    Menu {
                        Button(L10n.text("action.archive")) { store.organize(ids: ids, archived: true) }
                        Button(L10n.text("organize.unarchive")) { store.organize(ids: ids, archived: false) }
                        Menu(L10n.text("help.pick_colour")) {
                            ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { i, color in
                                Button(color.localizedName) { store.organize(ids: ids, color: i) }
                            }
                        }
                        Button(L10n.text("organize.merge")) {
                            if let merged = store.merge(ids: ids) {
                                model.criteria = NoteQuery(); model.selection = [merged.id]
                            }
                        }.disabled(selected.count < 2)
                        Button(L10n.text("organize.float")) { FloatingNotes.shared.open(ids: selected.map(\.id)) }
                        Divider()
                        exportButtons(selected)
                    } label: { Label(L10n.text("organize.actions"), systemImage: "ellipsis.circle") }
                    Button { store.trash(ids: ids) } label: { Image(systemName: "trash") }
                        .help(L10n.text("organize.trash"))
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(12)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Picker("", selection: $model.criteria.scope) {
                ForEach(NoteScope.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            TextField(L10n.text("organize.search"), text: $model.criteria.text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Menu {
                    Button(L10n.text("organize.all_projects")) { model.criteria.project = nil }
                    Button(L10n.text("organize.no_project")) { model.criteria.project = "" }
                    ForEach(store.projects, id: \.self) { project in
                        Button(project) { model.criteria.project = project }
                    }
                } label: { Text(model.criteria.project.map { $0.isEmpty ? L10n.text("organize.no_project") : $0 }
                                ?? L10n.text("organize.all_projects")).lineLimit(1) }
                Menu {
                    Button(L10n.text("organize.all_tags")) { model.criteria.tag = nil }
                    ForEach(store.tags, id: \.self) { tag in Button(tag) { model.criteria.tag = tag } }
                } label: { Text(model.criteria.tag ?? L10n.text("organize.all_tags")).lineLimit(1) }
            }
            HStack {
                Menu {
                    Button(L10n.text("organize.all_colors")) { model.criteria.color = nil }
                    ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { i, color in
                        Button(color.localizedName) { model.criteria.color = i }
                    }
                } label: { Text(model.criteria.color.map { NoteColor.at($0).localizedName }
                                ?? L10n.text("organize.all_colors")) }
                Picker("", selection: $model.criteria.sort) {
                    ForEach(NoteSort.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if filtered.isEmpty {
                ContentUnavailableView(L10n.text("library.no_matches"), systemImage: "tray")
            } else {
                List(filtered, selection: $model.selection) { note in
                    row(note).tag(note.id)
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Button(L10n.text("organize.select_all")) { model.selection = Set(filtered.map(\.id)) }
                Spacer()
                Text("\(filtered.count)").foregroundStyle(.secondary)
                Menu {
                    exportButtons(store.living)
                    Divider()
                    Button(L10n.text("menu.import")) { Transfer.importFiles() }
                } label: { Image(systemName: "square.and.arrow.up") }
            }.controlSize(.small)
        }.padding(12)
    }

    @ViewBuilder private func exportButtons(_ notes: [Note]) -> some View {
        Button(L10n.text("export.markdown_per_note")) { Transfer.export(.markdown, notes: notes) }
        Button(L10n.text("export.plain_per_note")) { Transfer.export(.plainText, notes: notes) }
        Button(L10n.text("export.single_document")) { Transfer.export(.singleFile, notes: notes) }
        Button(L10n.text("export.sticky_archive")) { Transfer.export(.stickies, notes: notes) }
    }

    private func row(_ note: Note) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(note.palette.dash).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if note.archived { Image(systemName: "archivebox").foregroundStyle(.secondary) }
                }
                if !note.project.isEmpty || !note.tags.isEmpty {
                    Text(([note.project].filter { !$0.isEmpty } + note.tags.map { "#" + $0 }).joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(note.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(Fmt.ago(note.modified))
                    if let progress = note.taskProgress { Text("\(progress.done)/\(progress.total) ✓") }
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var detail: some View {
        if selected.count == 1, let note = selected.first {
            LibraryDetail(note: note, bridge: model.bridge).id(note.id)
        } else {
            VStack(spacing: 16) {
                Image(systemName: selected.isEmpty ? "sidebar.right" : "square.stack.3d.up")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text(selected.isEmpty ? L10n.text("library.select_note") : L10n.format("organize.selected", selected.count))
                Text(L10n.text("organize.selection_hint")).foregroundStyle(.secondary)
                if selected.count > 1 && !inTrash {
                    Button(L10n.text("organize.spread")) { NoteBoardWindow.shared.show(ids: selected.map(\.id)) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Detail pane

struct LibraryDetail: View {
    let note: Note
    let bridge: EditorBridge
    @State private var organizing = false

    @ObservedObject private var store = NoteStore.shared
    private var text: String { store.note(id: note.id)?.body ?? "" }
    private var title: String { store.note(id: note.id)?.title ?? "" }
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { store.updateBody(id: note.id, body: $0) })
    }
    private var titleBinding: Binding<String> {
        Binding(get: { title }, set: { store.updateTitle(id: note.id, title: $0) })
    }

    private var pal: NoteColor { note.palette }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { NoteStore.shared.cycleColor(id: note.id) } label: {
                    Circle().fill(pal.dash).frame(width: 12, height: 12)
                        .padding(3).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("help.pick_colour"))
                .contextMenu {
                    ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                        Button(idx == note.color ? "✓ \(c.localizedName)" : c.localizedName) {
                            NoteStore.shared.setColor(id: note.id, color: idx)
                        }
                    }
                }
                .disabled(note.isTrashed)

                ZStack(alignment: .leading) {
                    if title.isEmpty {
                        Text(note.hasCustomTitle ? L10n.text("note.title_prompt") : (Note.derivedTitle(from: text).isEmpty ? L10n.text("note.untitled") : Note.derivedTitle(from: text)))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: titleBinding)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .disabled(note.isTrashed)
                }
                .font(Ink.bodyFont(13).weight(.semibold))
                .contextMenu {
                    if note.hasCustomTitle {
                        Button(L10n.text("note.title_reset")) {
                            NoteStore.shared.updateTitle(id: note.id, title: "")
                        }
                    }
                }

                Spacer()
                Text(store.unsavedIDs.contains(note.id) ? L10n.text("note.not_saved")
                     : L10n.format("note.edited", Fmt.ago(note.modified)))
                    .font(Ink.bodyFont(10.5)).foregroundStyle(.secondary)

                NoteTextDirectionMenu(direction: note.textDirection,
                                      foreground: .secondary) {
                    NoteStore.shared.setTextDirection(id: note.id, direction: $0)
                }
                .disabled(note.isTrashed)

                if note.isTrashed {
                    Button(L10n.text("action.restore")) { store.restore(ids: [note.id]) }
                        .controlSize(.small)
                } else if note.archived {
                    Button(L10n.text("action.restore")) { NoteStore.shared.setArchived(id: note.id, false) }
                        .controlSize(.small)
                } else {
                    Button(L10n.text("action.archive")) { NoteStore.shared.setArchived(id: note.id, true) }
                        .controlSize(.small)
                }
                Button {
                    NoteStore.shared.delete(id: note.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(note.isTrashed)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(pal.dash.opacity(0.12))

            HStack {
                Text(([note.project].filter { !$0.isEmpty } + note.tags.map { "#" + $0 }).joined(separator: " · "))
                    .lineLimit(2).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("organize.edit")) { organizing = true }.disabled(note.isTrashed)
                Button { FloatingNotes.shared.open(ids: [note.id]) } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }.disabled(note.isTrashed).help(L10n.text("organize.float"))
                NoteWindowButtons(noteID: note.id).disabled(note.isTrashed)
            }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)

            NoteFormattingBar(bridge: bridge, foreground: pal.ink.opacity(0.8))
                .disabled(note.isTrashed)
                .background(pal.paper)
            NoteTextView(text: textBinding, ink: NSColor(pal.ink), bridge: bridge,
                         autofocus: false, fontSize: Settings.noteFontSize,
                         markdownEnabled: Settings.markdownStyling,
                         textDirection: note.textDirection,
                         styleToken: "\(note.color)|\(Settings.noteFontSize)|\(Settings.noteFontName)|\(Settings.markdownStyling)",
                         editable: !note.isTrashed)
                .background(pal.paper)
                .disabled(note.isTrashed)
        }
        .onDisappear { store.flush(id: note.id) }
        .sheet(isPresented: $organizing) { OrganizationSheet(notes: [note]) }
    }
}
