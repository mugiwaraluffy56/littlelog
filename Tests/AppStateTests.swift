import Foundation
import SwiftData
import Testing
@testable import littlelog

@MainActor
struct AppStateTests {
    /// A clock the test can move forward.
    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let container: ModelContainer
    private let clock: Clock
    private let library: Library
    private let state: AppState

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let clock = Clock(try #require(ISO8601DateFormatter().date(from: "2026-10-16T06:00:00Z")))
        self.clock = clock
        library = Library(context: container.mainContext, calendar: calendar, now: { clock.now })
        state = AppState(library: library)
    }

    private func notes() throws -> [Note] {
        try container.mainContext.fetch(FetchDescriptor<Note>())
    }

    private func tasks(on dayKey: String) throws -> [DailyTask] {
        try container.mainContext.fetch(DailyTask.descriptor(for: dayKey))
    }

    // MARK: Notes

    @Test func abandonedDraftIsDiscarded() throws {
        state.newNote()
        #expect(state.openNote != nil)
        state.closeEditor()
        #expect(state.openNote == nil)
        #expect(try notes().isEmpty)
    }

    @Test func newNoteReusesAnUntouchedDraft() throws {
        state.newNote()
        let draft = try #require(state.openNote)
        state.newNote()
        #expect(state.openNote?.id == draft.id)
        #expect(try notes().count == 1)
    }

    @Test func writtenNoteIsKeptAfterClosing() throws {
        state.newNote()
        let note = try #require(state.openNote)
        note.content = "an idea"
        library.noteDidChange(note)
        state.closeEditor()
        #expect(try notes().map(\.content) == ["an idea"])
        #expect(state.highlightedNoteID == nil)
    }

    @Test func deletingANoteCanBeUndoneAndRedone() throws {
        state.newNote()
        let note = try #require(state.openNote)
        note.title = "keep me"
        let id = note.id
        state.deleteNote(note)
        #expect(state.openNote == nil)
        #expect(try notes().isEmpty)

        #expect(library.undoManager.canUndo)
        library.undoManager.undo()
        let restored = try notes()
        #expect(restored.map(\.id) == [id])
        #expect(restored.first?.title == "keep me")

        library.undoManager.redo()
        #expect(try notes().isEmpty)
    }

    @Test func purgeRemovesOnlyBlankNotes() throws {
        let context = container.mainContext
        context.insert(Note(title: "  ", content: "\n"))
        context.insert(Note(title: "real"))
        try context.save()
        library.purgeBlankNotes()
        #expect(try notes().map(\.title) == ["real"])
    }

    @Test func prepareForTerminationDropsBlankOpenDraft() throws {
        state.newNote()
        state.prepareForTermination()
        #expect(try notes().isEmpty)
    }

    // MARK: Escape

    @Test func escapeUnwindsEditorThenSearchThenHides() throws {
        state.newNote()
        let note = try #require(state.openNote)
        note.title = "x"
        state.searchText = "x"
        #expect(state.handleEscape())       // closes the editor
        #expect(state.openNote == nil)
        #expect(state.handleEscape())       // clears the search
        #expect(state.searchText.isEmpty)
        #expect(!state.handleEscape())      // nothing left: the panel should hide
    }

    // MARK: Keyboard highlight

    @Test func arrowKeysMoveWithinVisibleNotes() {
        let ids = [UUID(), UUID(), UUID()]
        state.updateVisibleNotes(ids)
        #expect(state.highlightedNoteID == nil)     // nothing is highlighted until an arrow key
        #expect(state.moveHighlight(by: 1))
        #expect(state.highlightedNoteID == ids[0])
        #expect(state.moveHighlight(by: 1))
        #expect(state.highlightedNoteID == ids[1])
        #expect(state.moveHighlight(by: 5))
        #expect(state.highlightedNoteID == ids[2])
        #expect(state.moveHighlight(by: -9))
        #expect(state.highlightedNoteID == ids[0])

        state.select(.today)
        #expect(!state.moveHighlight(by: 1))
    }

    // MARK: Today

    @Test func addedTasksAppendInOrder() throws {
        for text in ["one", "two", "  ", "three"] {
            state.newTaskDraft = text
            state.addTask()
        }
        let today = try tasks(on: "2026-10-16")
        #expect(today.map(\.text) == ["one", "two", "three"])
        #expect(today.map(\.position) == [0, 1, 2])
        #expect(state.newTaskDraft.isEmpty)
    }

    @Test func reorderingRenumbersPositionsAndTogglingKeepsOrder() throws {
        for text in ["a", "b", "c"] {
            state.newTaskDraft = text
            state.addTask()
        }
        library.moveTasks(try tasks(on: "2026-10-16"), from: [2], to: 0)
        #expect(try tasks(on: "2026-10-16").map(\.text) == ["c", "a", "b"])

        let b = try #require(try tasks(on: "2026-10-16").last)
        library.toggle(b)
        let after = try tasks(on: "2026-10-16")
        #expect(after.map(\.text) == ["c", "a", "b"])
        #expect(after.last?.isCompleted == true)
    }

    @Test func clearingATaskWhileEditingDeletesIt() throws {
        state.newTaskDraft = "temporary"
        state.addTask()
        let task = try #require(try tasks(on: "2026-10-16").first)
        state.beginEditing(task)
        task.text = "   "
        state.endEditingTask()
        #expect(try tasks(on: "2026-10-16").isEmpty)
    }

    @Test func deletingATaskCanBeUndone() throws {
        state.newTaskDraft = "write documentation"
        state.addTask()
        let task = try #require(try tasks(on: "2026-10-16").first)
        library.removeTaskReportingErrors(task)
        #expect(try tasks(on: "2026-10-16").isEmpty)
        library.undoManager.undo()
        #expect(try tasks(on: "2026-10-16").map(\.text) == ["write documentation"])
    }

    @Test func newDayShowsOnlyItsOwnTasksAndKeepsYesterday() throws {
        state.newTaskDraft = "yesterday's task"
        state.addTask()
        #expect(library.dayKey == "2026-10-16")

        // 18:30 UTC is midnight in Kolkata.
        clock.now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T18:30:00Z"))
        library.refreshDay()
        #expect(library.dayKey == "2026-10-17")
        #expect(try tasks(on: "2026-10-17").isEmpty)

        state.newTaskDraft = "today's task"
        state.addTask()
        #expect(try tasks(on: "2026-10-17").map(\.text) == ["today's task"])
        #expect(try tasks(on: "2026-10-16").map(\.text) == ["yesterday's task"])
    }
}
