import Foundation
import SwiftData
import Testing
@testable import littlelog

@MainActor
struct PersistenceTests {
    @Test func notesAndTasksSurviveReopeningTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlelog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")

        let noteID: UUID
        do {
            let container = try Persistence.makeContainer(url: url)
            let state = AppState(context: container.mainContext)
            state.newNote()
            let note = try #require(state.openNote)
            note.title = "groceries"
            note.content = "eggs\nmilk"
            state.noteDidChange(note)
            noteID = note.id
            state.closeEditor()

            state.newTaskDraft = "review pull request"
            state.addTask()
        }

        let reopened = try Persistence.makeContainer(url: url)
        let context = reopened.mainContext
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.map(\.id) == [noteID])
        #expect(notes.first?.content == "eggs\nmilk")

        let tasks = try context.fetch(FetchDescriptor<DailyTask>())
        #expect(tasks.map(\.text) == ["review pull request"])
    }

    @Test func duplicateIDsAreMergedNotDuplicated() throws {
        let container = try Persistence.makeInMemoryContainer()
        let context = container.mainContext
        let id = UUID()
        context.insert(Note(id: id, title: "first"))
        try context.save()
        context.insert(Note(id: id, title: "second"))
        try context.save()

        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
    }
}
