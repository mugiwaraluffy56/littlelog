import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

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

struct FocusRequest: Equatable {
    let target: FocusTarget
    let token = UUID()
}

extension Logger {
    static let app = Logger(subsystem: "dev.littlelog.app", category: "app")
}

/// All UI state and every mutation of the library. Lives for the whole app session,
/// so section, open note and drafts survive hiding the panel.
@Observable
final class AppState {
    let context: ModelContext
    let undoManager = UndoManager()

    private(set) var section: AppSection = .notes
    private(set) var openNote: Note?
    private(set) var editingTask: DailyTask?
    private(set) var dayKey: String
    private(set) var day: Date
    private(set) var focusRequest: FocusRequest?
    private(set) var errorMessage: String?

    var searchText = ""
    var newTaskDraft = ""
    var highlightedNoteID: UUID?
    /// Set only by keyboard navigation, so hovering never scrolls the list.
    private(set) var scrollTargetNoteID: UUID?

    @ObservationIgnored private var visibleNoteIDs: [UUID] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dayObservers: [NSObjectProtocol] = []
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored let now: () -> Date

    init(
        context: ModelContext,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.calendar = calendar
        self.now = now
        let date = now()
        day = date
        dayKey = DayKey.make(for: date, calendar: calendar)
        context.autosaveEnabled = false
    }

    var editingTaskID: UUID? { editingTask?.id }

    // MARK: Panel lifecycle

    func panelWillAppear() {
        refreshDay()
        requestFocus(defaultFocus)
    }

    func panelDidHide() {
        save()
    }

    func prepareForTermination() {
        endEditingTask(restoreFocus: false)
        if let note = openNote, note.isBlank {
            openNote = nil
            context.delete(note)
        }
        save()
    }

    /// Returns `true` when Escape was consumed by the current context; otherwise the panel hides.
    func handleEscape() -> Bool {
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

    /// ⌘N: a new note in Notes, the task field in Today.
    func newItem() {
        switch section {
        case .notes: newNote()
        case .today: requestFocus(.newTask)
        }
    }

    func focusSearch() {
        if section != .notes {
            endEditingTask(restoreFocus: false)
            section = .notes
        }
        closeEditor(restoreFocus: false)
        requestFocus(.search)
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
        let note = Note(createdAt: now())
        context.insert(note)
        searchText = ""
        openNote = note
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
            guard let note = try context.fetch(Note.descriptor(id: id)).first else { return }
            open(note)
        } catch {
            report(error, "couldn't open the note")
        }
    }

    /// Leaves the editor. An untouched draft is discarded instead of being kept as an empty note.
    func closeEditor(restoreFocus: Bool = true) {
        guard let note = openNote else { return }
        openNote = nil
        if note.isBlank {
            context.delete(note)
        }
        save()
        if restoreFocus { requestFocus(.search) }
    }

    func noteDidChange(_ note: Note) {
        note.updatedAt = now()
        scheduleSave()
    }

    func deleteNote(_ note: Note) {
        let wasOpen = openNote?.id == note.id
        if wasOpen { openNote = nil }
        if highlightedNoteID == note.id { highlightedNoteID = nil }
        let snapshot = note.isBlank ? nil : NoteSnapshot(note)
        context.delete(note)
        save()
        if let snapshot {
            undoManager.registerUndo(withTarget: self) { state in
                state.restoreNote(snapshot)
            }
            undoManager.setActionName("Delete Note")
        }
        if wasOpen { requestFocus(.search) }
    }

    private func deleteNote(id: UUID) {
        do {
            guard let note = try context.fetch(Note.descriptor(id: id)).first else { return }
            deleteNote(note)
        } catch {
            report(error, "couldn't delete the note")
        }
    }

    private func restoreNote(_ snapshot: NoteSnapshot) {
        context.insert(snapshot.makeNote())
        save()
        undoManager.registerUndo(withTarget: self) { state in
            state.deleteNote(id: snapshot.id)
        }
        undoManager.setActionName("Delete Note")
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
    func moveHighlight(by offset: Int) -> Bool {
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

    func addTask() {
        let text = newTaskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try insertTask(text, on: dayKey)
            newTaskDraft = ""
            save()
        } catch {
            report(error, "couldn't add the task")
        }
    }

    /// Appends a task to the end of a day's list. The caller saves.
    @discardableResult
    func insertTask(_ text: String, on dayKey: String, byAssistant: Bool = false) throws -> DailyTask {
        var lastDescriptor = DailyTask.descriptor(for: dayKey)
        lastDescriptor.sortBy = [SortDescriptor(\.position, order: .reverse)]
        lastDescriptor.fetchLimit = 1
        let position = (try context.fetch(lastDescriptor).first?.position ?? -1) + 1
        let task = DailyTask(
            text: text,
            dateKey: dayKey,
            position: position,
            createdAt: now(),
            addedByAssistant: byAssistant
        )
        context.insert(task)
        return task
    }

    func toggle(_ task: DailyTask) {
        task.isCompleted.toggle()
        task.updatedAt = now()
        save()
    }

    func beginEditing(_ task: DailyTask) {
        guard editingTask?.id != task.id else { return }
        endEditingTask(restoreFocus: false)
        editingTask = task
        requestFocus(.task(task.id))
    }

    /// Commits inline task edits. Clearing a task's text removes it.
    func endEditingTask(restoreFocus: Bool = true) {
        guard let task = editingTask else { return }
        editingTask = nil
        let trimmed = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteTask(task)
        } else {
            if trimmed != task.text { task.text = trimmed }
            save()
        }
        if restoreFocus { requestFocus(.newTask) }
    }

    func taskTextDidChange(_ task: DailyTask) {
        task.updatedAt = now()
        scheduleSave()
    }

    func deleteTask(_ task: DailyTask) {
        do {
            try removeTask(task)
        } catch {
            // `commit()` has already surfaced the failure in `errorMessage` and the log.
            return
        }
    }

    /// Deletes a task and registers ⌘Z to restore it.
    func removeTask(_ task: DailyTask) throws {
        if editingTask?.id == task.id { editingTask = nil }
        let snapshot = TaskSnapshot(task)
        context.delete(task)
        try commit()
        guard !snapshot.text.isBlankText else { return }
        undoManager.registerUndo(withTarget: self) { state in
            state.restoreTask(snapshot)
        }
        undoManager.setActionName("Delete Task")
    }

    private func deleteTask(id: UUID) {
        do {
            guard let task = try context.fetch(DailyTask.descriptor(id: id)).first else { return }
            deleteTask(task)
        } catch {
            report(error, "couldn't delete the task")
        }
    }

    private func restoreTask(_ snapshot: TaskSnapshot) {
        context.insert(snapshot.makeTask())
        save()
        undoManager.registerUndo(withTarget: self) { state in
            state.deleteTask(id: snapshot.id)
        }
        undoManager.setActionName("Delete Task")
    }

    /// Applies a drag reorder by renumbering the day's tasks in their new order.
    func moveTasks(_ tasks: [DailyTask], from source: IndexSet, to destination: Int) {
        var ordered = tasks
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, task) in ordered.enumerated() where task.position != index {
            task.position = index
        }
        save()
    }

    // MARK: Day tracking

    func refreshDay() {
        let date = now()
        let key = DayKey.make(for: date, calendar: calendar)
        guard key != dayKey else { return }
        endEditingTask(restoreFocus: false)
        day = date
        dayKey = key
    }

    /// Midnight, time zone and clock changes are all delivered as notifications; no timers needed.
    func startObservingDayChanges() {
        guard dayObservers.isEmpty else { return }
        let names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange]
        dayObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshDay()
                }
            }
        }
    }

    // MARK: Persistence

    func purgeBlankNotes() {
        do {
            let blanks = try context.fetch(FetchDescriptor<Note>()).filter(\.isBlank)
            guard !blanks.isEmpty else { return }
            for note in blanks { context.delete(note) }
            save()
        } catch {
            report(error, "couldn't read your notes")
        }
    }

    func save() {
        do {
            try commit()
        } catch {
            // `commit()` has already surfaced the failure in `errorMessage` and the log.
            return
        }
    }

    /// Saves pending changes, surfacing failures in the UI and rethrowing them for callers
    /// (such as assistant tools) that must report the error back.
    func commit() throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard context.hasChanges else { return }
        do {
            try context.save()
            errorMessage = nil
        } catch {
            report(error, "couldn't save your changes")
            throw error
        }
    }

    /// Coalesces saves while typing so persistence never runs per keystroke.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            self?.save()
        }
    }

    private func report(_ error: any Error, _ message: String) {
        Logger.app.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        errorMessage = message
    }
}
