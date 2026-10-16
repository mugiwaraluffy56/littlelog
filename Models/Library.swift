import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

/// A problem with a request to the Library that the caller can show or correct.
enum LibraryError: LocalizedError, Equatable {
    case invalidArgument(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message), .notFound(let message): message
        }
    }
}

extension Logger {
    nonisolated static let app = Logger(subsystem: "dev.littlelog.app", category: "app")
}

/// Every rule about Notes and Tasks: creating, editing, ordering, deleting with undo, the current
/// Day, and saving. The Panel and ChatGPT both go through this one interface, so they get the
/// same validation, the same undo, and changes show live wherever they're displayed.
@Observable
final class Library {
    static let maxTaskLength = 500

    let context: ModelContext
    /// Shared with the panel window, so ⌘Z undoes deletions made from anywhere.
    let undoManager = UndoManager()

    private(set) var dayKey: String
    private(set) var day: Date
    private(set) var errorMessage: String?

    /// Called when the current Day rolls over and when a Task is removed, so UI state that refers
    /// to them (an inline edit) can let go.
    @ObservationIgnored var onDayChange: (() -> Void)?
    @ObservationIgnored var onTaskRemoved: ((UUID) -> Void)?

    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dayObservers: [NSObjectProtocol] = []

    init(context: ModelContext, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.calendar = calendar
        self.now = now
        let date = now()
        day = date
        dayKey = DayKey.make(for: date, calendar: calendar)
        context.autosaveEnabled = false
    }

    // MARK: Day

    func refreshDay() {
        let date = now()
        let key = DayKey.make(for: date, calendar: calendar)
        guard key != dayKey else { return }
        onDayChange?()
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

    /// Resolves "today", "tomorrow", "yesterday" or YYYY-MM-DD against the current local Day.
    func resolveDay(_ input: String?) throws -> String {
        refreshDay()
        guard let key = DayKey.resolve(input, now: now(), calendar: calendar) else {
            throw LibraryError.invalidArgument(
                "Unrecognized date \"\(input ?? "")\". Use today, tomorrow, yesterday, or YYYY-MM-DD."
            )
        }
        return key
    }

    // MARK: Notes

    /// A new, unsaved Note. It's saved once it has content; a blank one is discarded on close.
    func createNote() -> Note {
        let note = Note(createdAt: now())
        context.insert(note)
        return note
    }

    func note(id: UUID) throws -> Note? {
        try context.fetch(Note.descriptor(id: id)).first
    }

    /// Records an edit made through a binding; saving is coalesced while typing.
    func noteDidChange(_ note: Note) {
        note.updatedAt = now()
        scheduleSave()
    }

    /// Saves a Note that's being left, or deletes it if it was never written in.
    func finishEditing(_ note: Note) {
        if note.isBlank { context.delete(note) }
        save()
    }

    /// Deletes a Note and registers ⌘Z to restore it (blank drafts aren't worth restoring).
    func deleteNote(_ note: Note) {
        let snapshot = note.isBlank ? nil : NoteSnapshot(note)
        context.delete(note)
        save()
        guard let snapshot else { return }
        undoManager.registerUndo(withTarget: self) { library in
            library.restoreNote(snapshot)
        }
        undoManager.setActionName("Delete Note")
    }

    /// Notes matching a query in their title or body, most recently edited first.
    /// An empty query returns the most recent notes.
    func searchNotes(_ query: String, limit: Int) throws -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = try context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        let matches = notes.lazy.filter { note in
            !note.isBlank && (trimmed.isEmpty
                || note.title.localizedStandardContains(trimmed)
                || note.content.localizedStandardContains(trimmed))
        }
        return Array(matches.prefix(limit))
    }

    /// Removes drafts left blank by a crash or force quit.
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

    private func restoreNote(_ snapshot: NoteSnapshot) {
        context.insert(snapshot.makeNote())
        save()
        undoManager.registerUndo(withTarget: self) { library in
            do {
                if let note = try library.note(id: snapshot.id) { library.deleteNote(note) }
            } catch {
                library.report(error, "couldn't delete the note")
            }
        }
        undoManager.setActionName("Delete Note")
    }

    // MARK: Tasks

    func tasks(on dayKey: String) throws -> [DailyTask] {
        try context.fetch(DailyTask.descriptor(for: dayKey))
    }

    func task(id: UUID) throws -> DailyTask {
        guard let task = try context.fetch(DailyTask.descriptor(id: id)).first else {
            throw LibraryError.notFound("No task has id \(id.uuidString). Call list_tasks to get current ids.")
        }
        return task
    }

    /// Appends one Task to the end of a Day's list and saves.
    @discardableResult
    func addTask(_ text: String, on dayKey: String) throws -> DailyTask {
        let trimmed = try validTaskText(text)
        let task = try insertTask(trimmed, on: dayKey, byAssistant: false)
        try commit()
        return task
    }

    /// Adds Tasks in order, skipping blanks and anything already on that Day's list (compared
    /// case- and accent-insensitively), so a retried request never creates duplicates.
    func addTasks(_ texts: [String], on dayKey: String, byAssistant: Bool) throws -> (added: [DailyTask], skipped: [(text: String, reason: String)]) {
        var seen = Set(try tasks(on: dayKey).map { Self.comparisonKey($0.text) })
        var added: [DailyTask] = []
        var skipped: [(text: String, reason: String)] = []
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                skipped.append((raw, "empty"))
                continue
            }
            guard text.count <= Self.maxTaskLength else {
                skipped.append((text, "longer than \(Self.maxTaskLength) characters"))
                continue
            }
            guard seen.insert(Self.comparisonKey(text)).inserted else {
                skipped.append((text, "already on the list"))
                continue
            }
            added.append(try insertTask(text, on: dayKey, byAssistant: byAssistant))
        }
        try commit()
        return (added, skipped)
    }

    func setCompleted(_ task: DailyTask, _ completed: Bool) throws {
        guard task.isCompleted != completed else { return }
        task.isCompleted = completed
        task.updatedAt = now()
        try commit()
    }

    func toggle(_ task: DailyTask) {
        do {
            try setCompleted(task, !task.isCompleted)
        } catch {
            // `commit()` has already surfaced the failure in `errorMessage` and the log.
            return
        }
    }

    func rename(_ task: DailyTask, to text: String) throws {
        task.text = try validTaskText(text)
        task.updatedAt = now()
        try commit()
    }

    /// Records an edit made through a binding; saving is coalesced while typing.
    func taskDidChange(_ task: DailyTask) {
        task.updatedAt = now()
        scheduleSave()
    }

    /// Settles a Task after inline editing: trims it, or deletes it if it was cleared.
    func finishEditing(_ task: DailyTask) {
        let trimmed = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeTaskReportingErrors(task)
        } else {
            if trimmed != task.text { task.text = trimmed }
            save()
        }
    }

    /// Deletes a Task and registers ⌘Z to restore it.
    func removeTask(_ task: DailyTask) throws {
        onTaskRemoved?(task.id)
        let snapshot = TaskSnapshot(task)
        context.delete(task)
        try commit()
        guard !snapshot.text.isBlankText else { return }
        undoManager.registerUndo(withTarget: self) { library in
            library.restoreTask(snapshot)
        }
        undoManager.setActionName("Delete Task")
    }

    func removeTaskReportingErrors(_ task: DailyTask) {
        do {
            try removeTask(task)
        } catch {
            // `commit()` has already surfaced the failure in `errorMessage` and the log.
            return
        }
    }

    /// Applies a drag reorder by renumbering the Day's tasks in their new order.
    func moveTasks(_ tasks: [DailyTask], from source: IndexSet, to destination: Int) {
        var ordered = tasks
        ordered.move(fromOffsets: source, toOffset: destination)
        renumber(ordered)
        save()
    }

    /// Moves a Task to a 0-based position within its Day, clamped to the list's bounds.
    func moveTask(_ task: DailyTask, to position: Int) throws -> [DailyTask] {
        var ordered = try tasks(on: task.dateKey)
        guard let from = ordered.firstIndex(where: { $0.id == task.id }) else {
            throw LibraryError.notFound("That task is no longer on its list.")
        }
        let moving = ordered.remove(at: from)
        ordered.insert(moving, at: min(max(position, 0), ordered.count))
        renumber(ordered)
        try commit()
        return ordered
    }

    private func insertTask(_ text: String, on dayKey: String, byAssistant: Bool) throws -> DailyTask {
        var lastDescriptor = DailyTask.descriptor(for: dayKey)
        lastDescriptor.sortBy = [SortDescriptor(\.position, order: .reverse)]
        lastDescriptor.fetchLimit = 1
        let position = (try context.fetch(lastDescriptor).first?.position ?? -1) + 1
        let task = DailyTask(text: text, dateKey: dayKey, position: position, createdAt: now(), addedByAssistant: byAssistant)
        context.insert(task)
        return task
    }

    private func restoreTask(_ snapshot: TaskSnapshot) {
        context.insert(snapshot.makeTask())
        save()
        undoManager.registerUndo(withTarget: self) { library in
            do {
                library.removeTaskReportingErrors(try library.task(id: snapshot.id))
            } catch {
                library.report(error, "couldn't delete the task")
            }
        }
        undoManager.setActionName("Delete Task")
    }

    private func renumber(_ ordered: [DailyTask]) {
        for (index, task) in ordered.enumerated() where task.position != index {
            task.position = index
        }
    }

    private func validTaskText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LibraryError.invalidArgument("Task text can't be empty. Use delete_task to remove a task.")
        }
        guard trimmed.count <= Self.maxTaskLength else {
            throw LibraryError.invalidArgument("Task text must be \(Self.maxTaskLength) characters or fewer.")
        }
        return trimmed
    }

    private static func comparisonKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: Saving

    func save() {
        do {
            try commit()
        } catch {
            // `commit()` has already surfaced the failure in `errorMessage` and the log.
            return
        }
    }

    /// Saves pending changes, surfacing failures in the UI and rethrowing them for callers
    /// (such as ChatGPT tools) that must report the error back.
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

    func report(_ error: any Error, _ message: String) {
        Logger.app.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        errorMessage = message
    }
}
