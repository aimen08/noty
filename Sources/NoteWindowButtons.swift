import SwiftUI

/// Opens the same note in its own window from the deck, library or wall.
struct NoteWindowButtons: View {
    let noteID: String
    var beforeOpen: () -> Void = {}

    var body: some View {
        Button {
            beforeOpen()
            FloatingNotes.shared.maximize(id: noteID)
        } label: {
            Image(systemName: "rectangle.expand.vertical").frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(L10n.text("note.maximize"))
        .accessibilityLabel(L10n.text("note.maximize"))
        Button {
            beforeOpen()
            FloatingNotes.shared.fullScreen(id: noteID)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(L10n.text("note.full_screen"))
        .accessibilityLabel(L10n.text("note.full_screen"))
    }
}
