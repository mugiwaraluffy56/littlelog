import Foundation
import SwiftData

enum AssistantError: LocalizedError, Equatable {
    case invalidArgument(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message), .notFound(let message): message
        }
    }
}

/// Operations behind the MCP tools. They go through the same model context as the UI, so changes
/// appear in the open panel immediately and deletions can be undone with ⌘Z.
extension AppState {
    static let maxTaskLength = 500

    /// Resolves an assistant-supplied date against the user's current local day.
    func assistantDayKey(_ input: String?) throws -> String {
        refreshDay()
        guard let key = DayKey.resolve(input, now: now(), calendar: calendar) else {
            throw AssistantError.invalidArgument(
                "Unrecognized date \"\(input ?? "")\". Use today, tomorrow, yesterday, or YYYY-MM-DD."
            )
        }
        return key
    }

    func tasks(on dayKey: String) throws -> [DailyTask] {
        try context.fetch(DailyTask.descriptor(for: dayKey))
    }

    func task(id: UUID) throws -> DailyTask {
        guard let task = try context.fetch(DailyTask.descriptor(id: id)).first else {
            throw AssistantError.notFound("No task has id \(id.uuidString). Call list_tasks to get current ids.")
        }
        return task
    }

    /// Adds tasks in order, skipping blanks and anything already on that day's list
    /// (compared case- and accent-insensitively) so retried calls never create duplicates.
    func addAssistantTasks(_ texts: [String], on dayKey: String) throws -> (added: [DailyTask], skipped: [(text: String, reason: String)]) {
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
            let key = Self.comparisonKey(text)
            guard seen.insert(key).inserted else {
                skipped.append((text, "already on the list"))
                continue
            }
            added.append(try insertTask(text, on: dayKey, byAssistant: true))
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

    func renameTask(_ task: DailyTask, to text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantError.invalidArgument("Task text can't be empty. Use delete_task to remove a task.")
        }
        guard trimmed.count <= Self.maxTaskLength else {
            throw AssistantError.invalidArgument("Task text must be \(Self.maxTaskLength) characters or fewer.")
        }
        if editingTask?.id == task.id { endEditingTask(restoreFocus: false) }
        task.text = trimmed
        task.updatedAt = now()
        try commit()
    }

    /// Moves a task to a 0-based position within its day, clamped to the list's bounds.
    func moveTask(_ task: DailyTask, to position: Int) throws -> [DailyTask] {
        var ordered = try tasks(on: task.dateKey)
        guard let from = ordered.firstIndex(where: { $0.id == task.id }) else {
            throw AssistantError.notFound("That task is no longer on its list.")
        }
        let moving = ordered.remove(at: from)
        ordered.insert(moving, at: min(max(position, 0), ordered.count))
        for (index, item) in ordered.enumerated() where item.position != index {
            item.position = index
        }
        try commit()
        return ordered
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

    func note(id: UUID) throws -> Note {
        guard let note = try context.fetch(Note.descriptor(id: id)).first, !note.isBlank else {
            throw AssistantError.notFound("No note has id \(id.uuidString). Call search_notes to find notes.")
        }
        return note
    }

    private static func comparisonKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
