import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case notes
    case today

    var id: Self { self }
}

enum FocusTarget: Hashable {
    case search
    case noteTitle
    case noteBody
    case newTask
    case task(UUID)
}

/// Everything the keyboard can ask the panel to do. The panel turns key events into commands;
/// `AppState.perform` is the one place that decides what each does in the current context.
enum PanelCommand: Equatable {
    case show(AppSection)
    case newItem
    case focusSearch
    case escape
    case openHighlightedNote
    case moveHighlight(Int)
}

struct FocusRequest: Equatable {
    let target: FocusTarget
    let token = UUID()
}

/// The Panel's state: which section is showing, the open Note, the Task being edited inline,
/// search, keyboard highlight and focus. Data changes go through the `Library`. Lives for the
/// whole session, so all of this survives hiding the panel.
@Observable
final class AppState {
    let library: Library

    private(set) var section: AppSection = .notes
    private(set) var openNote: Note?
    private(set) var editingTask: DailyTask?
    private(set) var focusRequest: FocusRequest?

    var searchText = ""
    var newTaskDraft = ""
    var highlightedNoteID: UUID?
    /// Set only by keyboard navigation, so hovering never scrolls the list.
    private(set) var scrollTargetNoteID: UUID?

    @ObservationIgnored private var visibleNoteIDs: [UUID] = []

    init(library: Library) {
        self.library = library
        library.onDayChange = { [weak self] in
            self?.endEditingTask(restoreFocus: false)
        }
        library.onTaskRemoved = { [weak self] id in
            if self?.editingTask?.id == id { self?.editingTask = nil }
        }
    }

    var editingTaskID: UUID? { editingTask?.id }

    // MARK: Commands

    /// Performs a keyboard command. Returns `false` when the current context has nothing for it
    /// to do, so the caller can fall back (Escape hides the panel; arrow keys reach the text field).
    @discardableResult
    func perform(_ command: PanelCommand) -> Bool {
        switch command {
        case .show(let section):
            select(section)
            return true
        case .newItem:
            switch section {
            case .notes: newNote()
            case .today: requestFocus(.newTask)
            }
            return true
        case .focusSearch:
            if section != .notes {
                endEditingTask(restoreFocus: false)
                section = .notes
            }
            closeEditor(restoreFocus: false)
            requestFocus(.search)
            return true
        case .escape:
            return handleEscape()
        case .openHighlightedNote:
            guard section == .notes, openNote == nil, highlightedNoteID != nil else { return false }
            openHighlightedNote()
            return true
        case .moveHighlight(let offset):
            return moveHighlight(by: offset)
        }
    }

    // MARK: Panel lifecycle

    func panelWillAppear() {
        library.refreshDay()
        requestFocus(defaultFocus)
    }

    func panelDidHide() {
        library.save()
    }

    func prepareForTermination() {
        endEditingTask(restoreFocus: false)
        if let note = openNote, note.isBlank {
            openNote = nil
            library.finishEditing(note)
        }
        library.save()
    }

    /// Returns `true` when Escape was consumed by the current context; otherwise the panel hides.
    private func handleEscape() -> Bool {
        if editingTask != nil {
            endEditingTask()
            return true
        }
        guard section == .notes else { return false }
        if openNote != nil {
            closeEditor()
            return true
        }
        if !searchText.isEmpty {
            searchText = ""
            return true
        }
        return false
    }

    // MARK: Navigation and focus

    var defaultFocus: FocusTarget {
        switch section {
        case .notes: openNote == nil ? .search : .noteBody
        case .today: .newTask
        }
    }

    func requestFocus(_ target: FocusTarget) {
        focusRequest = FocusRequest(target: target)
    }

    func select(_ section: AppSection) {
        if section != self.section {
            endEditingTask(restoreFocus: false)
            self.section = section
        }
        requestFocus(defaultFocus)
    }

    // MARK: Notes

    func newNote() {
        if section != .notes {
            endEditingTask(restoreFocus: false)
            section = .notes
        }
        if let openNote, openNote.isBlank {
            requestFocus(.noteTitle)
            return
        }
        closeEditor(restoreFocus: false)
        searchText = ""
        openNote = library.createNote()
        highlightedNoteID = nil
        requestFocus(.noteTitle)
    }

    func open(_ note: Note) {
        guard openNote?.id != note.id else {
            requestFocus(.noteBody)
            return
        }
        closeEditor(restoreFocus: false)
        openNote = note
        highlightedNoteID = nil
        requestFocus(.noteBody)
    }

    func openHighlightedNote() {
        guard let id = highlightedNoteID ?? visibleNoteIDs.first else { return }
        open(id: id)
    }

    func open(id: UUID) {
        guard openNote?.id != id else { return }
        do {
            guard let note = try library.note(id: id) else { return }
            open(note)
        } catch {
            library.report(error, "couldn't open the note")
        }
    }

    /// Leaves the editor. An untouched draft is discarded instead of being kept as an empty note.
    func closeEditor(restoreFocus: Bool = true) {
        guard let note = openNote else { return }
        openNote = nil
        library.finishEditing(note)
        if restoreFocus { requestFocus(.search) }
    }

    func deleteNote(_ note: Note) {
        let wasOpen = openNote?.id == note.id
        if wasOpen { openNote = nil }
        if highlightedNoteID == note.id { highlightedNoteID = nil }
        library.deleteNote(note)
        if wasOpen { requestFocus(.search) }
    }

    /// Called by the notes list whenever the filtered result changes. The highlight is only ever
    /// set by arrow keys, so it is dropped when its note leaves the list.
    func updateVisibleNotes(_ ids: [UUID]) {
        visibleNoteIDs = ids
        if let highlightedNoteID, !ids.contains(highlightedNoteID) {
            self.highlightedNoteID = nil
        }
    }

    /// Arrow-key navigation through the notes list. Returns `false` when not applicable.
    private func moveHighlight(by offset: Int) -> Bool {
        guard section == .notes, openNote == nil, !visibleNoteIDs.isEmpty else { return false }
        let current = highlightedNoteID.flatMap { visibleNoteIDs.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), visibleNoteIDs.count - 1)
        } else {
            next = offset > 0 ? 0 : visibleNoteIDs.count - 1
        }
        highlightedNoteID = visibleNoteIDs[next]
        scrollTargetNoteID = visibleNoteIDs[next]
        return true
    }

    // MARK: Today

    /// Adds the typed draft to Today and clears the field.
    func addTask() {
        guard !newTaskDraft.isBlankText else { return }
        do {
            try library.addTask(newTaskDraft, on: library.dayKey)
            newTaskDraft = ""
        } catch {
            library.report(error, "couldn't add the task")
        }
    }

    func beginEditing(_ task: DailyTask) {
        guard editingTask?.id != task.id else { return }
        endEditingTask(restoreFocus: false)
        editingTask = task
        requestFocus(.task(task.id))
    }

    /// Commits an inline edit. Clearing a task's text removes it.
    func endEditingTask(restoreFocus: Bool = true) {
        guard let task = editingTask else { return }
        editingTask = nil
        library.finishEditing(task)
        if restoreFocus { requestFocus(.newTask) }
    }
}
