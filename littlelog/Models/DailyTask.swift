import Foundation
import SwiftData

@Model
final class DailyTask {
    #Index<DailyTask>([\.dateKey])

    @Attribute(.unique) var id: UUID
    var text: String
    var dateKey: String
    var isCompleted: Bool
    var position: Int
    var createdAt: Date
    var updatedAt: Date
    /// Set when ChatGPT/Codex created the task over MCP. The default lets existing stores migrate.
    var addedByAssistant: Bool = false

    init(
        id: UUID = UUID(),
        text: String,
        dateKey: String,
        isCompleted: Bool = false,
        position: Int,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        addedByAssistant: Bool = false
    ) {
        self.id = id
        self.text = text
        self.dateKey = dateKey
        self.isCompleted = isCompleted
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.addedByAssistant = addedByAssistant
    }
}

extension DailyTask {
    /// Tasks for one local day, in their manual order.
    static func descriptor(for dayKey: String) -> FetchDescriptor<DailyTask> {
        FetchDescriptor(
            predicate: #Predicate { $0.dateKey == dayKey },
            sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]
        )
    }

    static func descriptor(id: UUID) -> FetchDescriptor<DailyTask> {
        var descriptor = FetchDescriptor<DailyTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return descriptor
    }
}

/// Plain values of a deleted task, used to restore it on undo.
struct TaskSnapshot: Sendable {
    let id: UUID
    let text: String
    let dateKey: String
    let isCompleted: Bool
    let position: Int
    let createdAt: Date
    let updatedAt: Date
    let addedByAssistant: Bool

    init(_ task: DailyTask) {
        id = task.id
        text = task.text
        dateKey = task.dateKey
        isCompleted = task.isCompleted
        position = task.position
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        addedByAssistant = task.addedByAssistant
    }

    func makeTask() -> DailyTask {
        DailyTask(
            id: id,
            text: text,
            dateKey: dateKey,
            isCompleted: isCompleted,
            position: position,
            createdAt: createdAt,
            updatedAt: updatedAt,
            addedByAssistant: addedByAssistant
        )
    }
}
