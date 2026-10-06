import SwiftUI

struct OrganizationSheet: View {
    let notes: [Note]
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var tags = ""
    @State private var changeProject = true
    @State private var changeTags = true
    @State private var addTags = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("organize.edit")).font(.title2.bold())
            Text(L10n.format("organize.selected", notes.count)).foregroundStyle(.secondary)
            Toggle(L10n.text("organize.project"), isOn: $changeProject)
            HStack {
                TextField(L10n.text("organize.project_prompt"), text: $project)
                    .textFieldStyle(.roundedBorder)
                Menu(L10n.text("organize.existing")) {
                    Button(L10n.text("organize.no_project")) { project = "" }
                    ForEach(NoteStore.shared.projects, id: \.self) { name in
                        Button(name) { project = name }
                    }
                }.fixedSize()
            }.disabled(!changeProject)
            Toggle(L10n.text("organize.tags"), isOn: $changeTags)
            TextField(L10n.text("organize.tags_prompt"), text: $tags)
                .textFieldStyle(.roundedBorder).disabled(!changeTags)
            if notes.count > 1 {
                Toggle(L10n.text("organize.add_tags"), isOn: $addTags).disabled(!changeTags)
            }
            HStack {
                Spacer()
                Button(L10n.text("organize.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("organize.save")) {
                    let parsed = tags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    if NoteStore.shared.organize(ids: Set(notes.map(\.id)),
                        project: changeProject ? project : nil, tags: changeTags ? parsed : nil,
                        addingTags: addTags) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(!changeProject && !changeTags)
            }
        }.padding(24).frame(width: 420)
        .onAppear {
            if notes.count == 1, let note = notes.first {
                project = note.project; tags = note.tags.joined(separator: ", ")
            } else {
                changeProject = false; changeTags = false; addTags = true
            }
        }
    }
}
