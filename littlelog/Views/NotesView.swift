import SwiftData
import SwiftUI

struct NotesListView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    var isSearchFocused: FocusState<Bool>.Binding

    private var filteredNotes: [Note] {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedStandardContains(query) || $0.content.localizedStandardContains(query)
        }
    }

    var body: some View {
        @Bindable var state = state
        let visible = filteredNotes
        ScrollViewReader { proxy in
            // No List selection: an inactive panel would draw it grey. The arrow-key highlight is a
            // clear glass row instead, and only appears while navigating with the keyboard.
            List {
                ForEach(visible) { note in
                    NavigationLink(value: note.id) {
                        NoteRow(note: note)
                    }
                    .id(note.id)
                    .listRowBackground(
                        KeyboardHighlight(isVisible: note.id == state.highlightedNoteID)
                    )
                    .contextMenu {
                        Button("Open") { state.open(note) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            state.deleteNote(note)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .onChange(of: state.scrollTargetNoteID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Here Yet", systemImage: "note.text")
                } description: {
                    Text("Press ⌘N to write a note.")
                } actions: {
                    Button("New Note") { state.newNote() }
                }
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: state.searchText)
            }
        }
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused(isSearchFocused)
        .onSubmit(of: .search) { state.openHighlightedNote() }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
                Button("New Note", systemImage: "square.and.pencil") {
                    state.newNote()
                }
                .help("New Note (⌘N)")
            }
        }
        .onChange(of: visible.map(\.id), initial: true) { _, ids in
            state.updateVisibleNotes(ids)
        }
    }
}

private struct KeyboardHighlight: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Color.clear
                .glassEffect(.clear, in: .rect(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}

/// Laid out like Apple Notes: a bold title, then the edit date and the first line of text.
private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt.shortEditStamp)
                    .monospacedDigit()
                Text(note.preview ?? "No additional text")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension Date {
    /// "9:46 PM" today, "Oct 12" this year, "Oct 12, 2025" otherwise.
    var shortEditStamp: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}
