import SwiftUI

struct NoteEditorView: View {
    @Environment(AppState.self) private var state
    @Environment(Library.self) private var library
    @Bindable var note: Note
    var focus: FocusState<FocusTarget?>.Binding

    /// NSTextView pads each line by 5pt; offsetting by it keeps body text aligned with the title.
    private let textViewLinePadding: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $note.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .lineLimit(1...3)
                .focused(focus, equals: .noteTitle)
                .onSubmit { focus.wrappedValue = .noteBody }
                .accessibilityLabel("Title")
                .padding(.horizontal, Style.contentInset)
                .padding(.top, 8)

            Text("Edited \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Style.contentInset)
                .padding(.top, 4)
                .padding(.bottom, 10)

            TextEditor(text: $note.content)
                .textEditorStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .focused(focus, equals: .noteBody)
                .padding(.horizontal, Style.contentInset - textViewLinePadding)
                .overlay(alignment: .topLeading) {
                    if note.content.isEmpty {
                        Text("Start writing")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Style.contentInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Note")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                Button("Delete Note", systemImage: "trash") {
                    state.deleteNote(note)
                }
                .help("Delete Note")
            }
        }
        .onChange(of: note.title) { library.noteDidChange(note) }
        .onChange(of: note.content) { library.noteDidChange(note) }
    }
}
