import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Note {
    var isBlank: Bool { title.isBlankText && content.isBlankText }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return contentLines.first ?? "untitled"
    }

    /// The first line of body text not already used as the title.
    var preview: String? {
        let lines = contentLines
        return title.isBlankText ? lines.dropFirst().first : lines.first
    }

    private var contentLines: [String] {
        Array(
            content
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(2)
        )
    }

    static func descriptor(id: UUID) -> FetchDescriptor<Note> {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return descriptor
    }
}

/// Plain values of a deleted note, used to restore it on undo.
struct NoteSnapshot: Sendable {
    let id: UUID
    let title: String
    let content: String
    let createdAt: Date
    let updatedAt: Date

    init(_ note: Note) {
        id = note.id
        title = note.title
        content = note.content
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }

    func makeNote() -> Note {
        Note(id: id, title: title, content: content, createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension String {
    nonisolated var isBlankText: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
