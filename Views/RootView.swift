import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: FocusTarget?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack(path: notePath) {
            ZStack {
                switch state.section {
                case .notes:
                    NotesListView(isSearchFocused: $isSearchFocused)
                case .today:
                    TodayView(focus: $focus)
                }
            }
            .transition(.opacity)
            .clearsWindowToolbar()
            .navigationDestination(for: UUID.self) { _ in
                if let note = state.openNote {
                    NoteEditorView(note: note, focus: $focus)
                        .clearsWindowToolbar()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SectionSwitcher()
            }
            // The switcher draws its own glass; no grey toolbar platter behind it.
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationTitle("littlelog")
        // The panel's glass runs under the toolbar instead of a separate dark toolbar strip.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = library.errorMessage {
                ErrorFooter(message: message)
            }
        }
        .overlay(alignment: .bottom) { ApprovalBanner() }
        .background { PanelBackground().ignoresSafeArea() }
        .frame(width: Style.panelSize.width, height: Style.panelSize.height)
        .animation(reduceMotion ? nil : Style.motion, value: state.section)
        .onChange(of: state.focusRequest) { _, request in
            guard let request else { return }
            // Wait one turn so a view inserted by the same change exists before focusing it.
            Task {
                await Task.yield()
                if request.target == .search {
                    isSearchFocused = true
                } else {
                    focus = request.target
                }
            }
        }
    }

    /// The note editor is the only pushed screen; the path mirrors `state.openNote`.
    private var notePath: Binding<[UUID]> {
        Binding(
            get: {
                guard state.section == .notes, let note = state.openNote else { return [] }
                return [note.id]
            },
            set: { path in
                guard state.section == .notes else { return }
                if let id = path.last {
                    state.open(id: id)
                } else {
                    state.closeEditor()
                }
            }
        )
    }
}

private struct ErrorFooter: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Style.contentInset)
            .padding(.vertical, 10)
            .background(.bar)
    }
}
