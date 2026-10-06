import AppKit
import SwiftUI

final class NoteBoardModel: ObservableObject {
    @Published var ids: [String] = []
    @Published var width: Double = 340
}

/// A scrollable wall keeps every selected note readable even when there are
/// more notes than can fit on a physical screen as separate windows.
final class NoteBoardWindow: NSObject, NSWindowDelegate {
    static let shared = NoteBoardWindow()
    private var window: NSWindow?
    let model = NoteBoardModel()

    func show(ids: [String]) {
        var seen = Set<String>()
        model.ids = ids.filter { seen.insert($0).inserted && NoteStore.shared.note(id: $0)?.isTrashed == false }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.text("organize.board")
            w.minSize = NSSize(width: 640, height: 440)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: NoteBoardView(model: model))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NoteStore.shared.flushAll()
        AppWindows.didClose(notification)
    }
}

struct NoteBoardView: View {
    @ObservedObject var model: NoteBoardModel
    @ObservedObject private var store = NoteStore.shared
    private var notes: [Note] {
        let byID = Dictionary(uniqueKeysWithValues: store.living.map { ($0.id, $0) })
        return model.ids.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("organize.board")).font(.headline)
                Text("\(notes.count)").foregroundStyle(.secondary)
                Spacer()
                Label(L10n.text("organize.card_size"), systemImage: "rectangle.expand.vertical")
                Slider(value: $model.width, in: 280...520).frame(width: 140)
                Menu {
                    Button(L10n.text("organize.float")) { FloatingNotes.shared.open(ids: notes.map(\.id)) }
                        .disabled(notes.isEmpty)
                    Button(L10n.text("organize.close_floating")) { FloatingNotes.shared.closeAll() }
                } label: { Label(L10n.text("organize.actions"), systemImage: "ellipsis.circle") }
            }.controlSize(.small).padding(14)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.width), spacing: 16)], spacing: 16) {
                    ForEach(notes) { note in NoteBoardCard(note: note).frame(height: 360) }
                }.padding(20)
            }
            if notes.isEmpty { Text(L10n.text("library.no_notes")).padding(30) }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NoteBoardCard: View {
    let note: Note
    @ObservedObject private var store = NoteStore.shared
    @StateObject private var bridge = EditorBridge()
    @State private var organizing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("", text: Binding(
                    get: { store.note(id: note.id)?.title ?? "" },
                    set: { store.updateTitle(id: note.id, title: $0) }))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .overlay(alignment: .leading) {
                        if note.title.isEmpty { Text(note.displayTitle).lineLimit(1).allowsHitTesting(false) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                Button { FloatingNotes.shared.open(ids: [note.id]) } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }.help(L10n.text("organize.float"))
                NoteWindowButtons(noteID: note.id)
                Menu {
                    Button(L10n.text("organize.edit")) { organizing = true }
                    Button(note.archived ? L10n.text("organize.unarchive") : L10n.text("action.archive")) {
                        store.setArchived(id: note.id, !note.archived)
                    }
                    Button(L10n.text("organize.trash")) { store.delete(id: note.id) }
                } label: { Image(systemName: "ellipsis.circle") }
            }.buttonStyle(.plain).padding(12)
            if !note.project.isEmpty || !note.tags.isEmpty {
                Text(([note.project].filter { !$0.isEmpty } + note.tags.map { "#" + $0 }).joined(separator: " · "))
                    .font(.caption).lineLimit(1).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            NoteFormattingBar(bridge: bridge, foreground: note.palette.ink.opacity(0.8))
            NoteTextView(text: Binding(get: { store.note(id: note.id)?.body ?? "" },
                                      set: { store.updateBody(id: note.id, body: $0) }),
                         ink: NSColor(note.palette.ink), bridge: bridge, autofocus: false,
                         fontSize: Settings.noteFontSize, markdownEnabled: Settings.markdownStyling,
                         textDirection: note.textDirection,
                         styleToken: "\(note.color)|\(Settings.noteFontName)|\(Settings.markdownStyling)")
        }
        .foregroundStyle(note.palette.ink)
        .background(note.palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(note.palette.dash.opacity(0.35)))
        .sheet(isPresented: $organizing) { OrganizationSheet(notes: [note]) }
        .onDisappear { store.flush(id: note.id) }
    }
}
