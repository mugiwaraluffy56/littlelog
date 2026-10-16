import Foundation

/// The MCP tools littlelog exposes. Tasks are fully manageable; notes are read-only.
final class AssistantTools {
    struct Outcome {
        let structured: JSONValue
        let isError: Bool
    }

    private struct Definition {
        let name: String
        let title: String
        let description: String
        let inputSchema: JSONValue
        let outputSchema: JSONValue
        let readOnly: Bool
        let destructive: Bool
        let idempotent: Bool

        var json: JSONValue {
            [
                "name": .string(name),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": inputSchema,
                "outputSchema": outputSchema,
                "annotations": [
                    "title": .string(title),
                    "readOnlyHint": .bool(readOnly),
                    "destructiveHint": .bool(destructive),
                    "idempotentHint": .bool(idempotent),
                    "openWorldHint": false,
                ],
            ]
        }
    }

    private let library: Library

    init(library: Library) {
        self.library = library
    }

    var definitions: [JSONValue] { Self.all.map(\.json) }

    /// Runs a tool. Problems with the call itself (bad arguments, unknown ids, failed saves) come
    /// back as an error outcome the model can read and correct, per the MCP spec.
    func call(_ name: String, arguments: JSONValue?) throws(UnknownTool) -> Outcome {
        let args = Arguments(arguments?.objectValue ?? [:])
        do {
            let structured: JSONValue = switch name {
            case "list_tasks": try listTasks(args)
            case "add_tasks": try addTasks(args)
            case "set_task_completed": try setTaskCompleted(args)
            case "update_task": try updateTask(args)
            case "move_task": try moveTask(args)
            case "delete_task": try deleteTask(args)
            case "search_notes": try searchNotes(args)
            case "read_note": try readNote(args)
            default: throw UnknownTool(name: name)
            }
            return Outcome(structured: structured, isError: false)
        } catch let error as UnknownTool {
            throw error
        } catch let error as LibraryError {
            return Outcome(structured: ["error": .string(error.localizedDescription)], isError: true)
        } catch {
            return Outcome(
                structured: ["error": .string("littlelog couldn't complete this: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    struct UnknownTool: Error {
        let name: String
    }

    // MARK: Tools

    private func listTasks(_ args: Arguments) throws -> JSONValue {
        let dayKey = try library.resolveDay(args.string("date"))
        let tasks = try library.tasks(on: dayKey)
        let completed = tasks.filter(\.isCompleted).count
        return dayPayload(dayKey).merging([
            "tasks": .array(tasks.map(taskPayload)),
            "remaining": .int(tasks.count - completed),
            "completed": .int(completed),
        ])
    }

    private func addTasks(_ args: Arguments) throws -> JSONValue {
        let dayKey = try library.resolveDay(args.string("date"))
        let texts = try args.requiredStrings("tasks")
        guard (1...50).contains(texts.count) else {
            throw LibraryError.invalidArgument("Provide between 1 and 50 tasks.")
        }
        let result = try library.addTasks(texts, on: dayKey, byAssistant: true)
        return dayPayload(dayKey).merging([
            "added": .array(result.added.map(taskPayload)),
            "skipped": .array(result.skipped.map { ["text": .string($0.text), "reason": .string($0.reason)] }),
        ])
    }

    private func setTaskCompleted(_ args: Arguments) throws -> JSONValue {
        let task = try library.task(id: args.requiredUUID("id"))
        try library.setCompleted(task, args.requiredBool("completed"))
        return ["task": taskPayload(task)]
    }

    private func updateTask(_ args: Arguments) throws -> JSONValue {
        let task = try library.task(id: args.requiredUUID("id"))
        try library.rename(task, to: args.requiredString("text"))
        return ["task": taskPayload(task)]
    }

    private func moveTask(_ args: Arguments) throws -> JSONValue {
        let task = try library.task(id: args.requiredUUID("id"))
        let ordered = try library.moveTask(task, to: args.requiredInt("position"))
        return dayPayload(task.dateKey).merging(["tasks": .array(ordered.map(taskPayload))])
    }

    private func deleteTask(_ args: Arguments) throws -> JSONValue {
        let task = try library.task(id: args.requiredUUID("id"))
        let payload = taskPayload(task)
        try library.removeTask(task)
        return ["deleted": payload]
    }

    private func searchNotes(_ args: Arguments) throws -> JSONValue {
        let limit = try args.int("limit") ?? 10
        guard (1...50).contains(limit) else {
            throw LibraryError.invalidArgument("limit must be between 1 and 50.")
        }
        let notes = try library.searchNotes(args.string("query") ?? "", limit: limit)
        return ["notes": .array(notes.map { note in
            [
                "id": .string(note.id.uuidString),
                "title": .string(note.displayTitle),
                "preview": note.preview.map(JSONValue.string) ?? .null,
                "updated_at": .string(note.updatedAt.ISO8601Format()),
            ]
        })]
    }

    private func readNote(_ args: Arguments) throws -> JSONValue {
        let id = try args.requiredUUID("id")
        guard let note = try library.note(id: id), !note.isBlank else {
            throw LibraryError.notFound("No note has id \(id.uuidString). Call search_notes to find notes.")
        }
        return [
            "id": .string(note.id.uuidString),
            "title": .string(note.displayTitle),
            "content": .string(note.content),
            "created_at": .string(note.createdAt.ISO8601Format()),
            "updated_at": .string(note.updatedAt.ISO8601Format()),
        ]
    }

    // MARK: Payloads

    private func taskPayload(_ task: DailyTask) -> JSONValue {
        [
            "id": .string(task.id.uuidString),
            "text": .string(task.text),
            "completed": .bool(task.isCompleted),
            "position": .int(task.position),
            "added_by": .string(task.addedByAssistant ? "assistant" : "user"),
        ]
    }

    private func dayPayload(_ dayKey: String) -> JSONValue {
        let today = library.dayKey
        let calendar = library.calendar
        var relative: JSONValue = .null
        for (offset, word) in [(0, "today"), (1, "tomorrow"), (-1, "yesterday")] {
            if let date = calendar.date(byAdding: .day, value: offset, to: library.now()),
               DayKey.make(for: date, calendar: calendar) == dayKey {
                relative = .string(word)
            }
        }
        let label = DayKey.date(for: dayKey, calendar: calendar)
            .map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) } ?? dayKey
        return ["date": .string(dayKey), "label": .string(label), "relative": relative, "today": .string(today)]
    }

    // MARK: Definitions

    private static let dateProperty: JSONValue = [
        "type": "string",
        "description": "Local day: \"today\" (default), \"tomorrow\", \"yesterday\", or YYYY-MM-DD.",
    ]
    private static let idProperty: JSONValue = [
        "type": "string",
        "format": "uuid",
        "description": "Task id from list_tasks or add_tasks.",
    ]
    private static let taskSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string"],
            "text": ["type": "string"],
            "completed": ["type": "boolean"],
            "position": ["type": "integer"],
            "added_by": ["type": "string", "enum": ["user", "assistant"]],
        ],
        "required": ["id", "text", "completed", "position", "added_by"],
    ]
    private static let dayProperties: [String: JSONValue] = [
        "date": ["type": "string"],
        "label": ["type": "string"],
        "relative": ["type": ["string", "null"]],
        "today": ["type": "string"],
    ]

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    private static let all: [Definition] = [
        Definition(
            name: "list_tasks",
            title: "List Tasks",
            description: "Lists the user's tasks for one day in their chosen order, with completion library. Use this before changing tasks to get current ids.",
            inputSchema: object(["date": dateProperty], required: []),
            outputSchema: object(dayProperties.merging([
                "tasks": ["type": "array", "items": taskSchema],
                "remaining": ["type": "integer"],
                "completed": ["type": "integer"],
            ]) { _, new in new }, required: ["date", "label", "tasks", "remaining", "completed"]),
            readOnly: true, destructive: false, idempotent: true
        ),
        Definition(
            name: "add_tasks",
            title: "Add Tasks",
            description: "Appends tasks to a day's list (today by default). Tasks already on that day's list are skipped, so repeating a call is safe.",
            inputSchema: object([
                "tasks": [
                    "type": "array",
                    "items": ["type": "string", "minLength": 1, "maxLength": .int(Library.maxTaskLength)],
                    "minItems": 1,
                    "maxItems": 50,
                    "description": "Short task texts, in the user's words.",
                ],
                "date": dateProperty,
            ], required: ["tasks"]),
            outputSchema: object(dayProperties.merging([
                "added": ["type": "array", "items": taskSchema],
                "skipped": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["text": ["type": "string"], "reason": ["type": "string"]],
                ]],
            ]) { _, new in new }, required: ["date", "added", "skipped"]),
            readOnly: false, destructive: false, idempotent: true
        ),
        Definition(
            name: "set_task_completed",
            title: "Complete Task",
            description: "Marks a task as done or not done.",
            inputSchema: object(["id": idProperty, "completed": ["type": "boolean"]], required: ["id", "completed"]),
            outputSchema: object(["task": taskSchema], required: ["task"]),
            readOnly: false, destructive: false, idempotent: true
        ),
        Definition(
            name: "update_task",
            title: "Edit Task",
            description: "Replaces a task's text.",
            inputSchema: object([
                "id": idProperty,
                "text": ["type": "string", "minLength": 1, "maxLength": .int(Library.maxTaskLength)],
            ], required: ["id", "text"]),
            outputSchema: object(["task": taskSchema], required: ["task"]),
            readOnly: false, destructive: false, idempotent: true
        ),
        Definition(
            name: "move_task",
            title: "Reorder Task",
            description: "Moves a task to a 0-based position within its day's list, e.g. 0 to put it first.",
            inputSchema: object(["id": idProperty, "position": ["type": "integer", "minimum": 0]], required: ["id", "position"]),
            outputSchema: object(dayProperties.merging([
                "tasks": ["type": "array", "items": taskSchema],
            ]) { _, new in new }, required: ["date", "tasks"]),
            readOnly: false, destructive: false, idempotent: true
        ),
        Definition(
            name: "delete_task",
            title: "Delete Task",
            description: "Permanently deletes a task. Only do this when the user asks; prefer set_task_completed for finished tasks.",
            inputSchema: object(["id": idProperty], required: ["id"]),
            outputSchema: object(["deleted": taskSchema], required: ["deleted"]),
            readOnly: false, destructive: true, idempotent: false
        ),
        Definition(
            name: "search_notes",
            title: "Search Notes",
            description: "Finds the user's notes by words in the title or body, most recently edited first. An empty query returns recent notes. Notes are read-only.",
            inputSchema: object([
                "query": ["type": "string"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10."],
            ], required: []),
            outputSchema: object(["notes": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "title": ["type": "string"],
                    "preview": ["type": ["string", "null"]],
                    "updated_at": ["type": "string"],
                ],
            ]]], required: ["notes"]),
            readOnly: true, destructive: false, idempotent: true
        ),
        Definition(
            name: "read_note",
            title: "Read Note",
            description: "Returns one note's full text.",
            inputSchema: object(["id": ["type": "string", "format": "uuid", "description": "Note id from search_notes."]], required: ["id"]),
            outputSchema: object([
                "id": ["type": "string"],
                "title": ["type": "string"],
                "content": ["type": "string"],
                "created_at": ["type": "string"],
                "updated_at": ["type": "string"],
            ], required: ["id", "title", "content"]),
            readOnly: true, destructive: false, idempotent: true
        ),
    ]
}

/// Typed access to tool arguments with model-readable error messages.
private struct Arguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let string = value.stringValue else { throw LibraryError.invalidArgument("\(key) must be a string.") }
        return string
    }

    func requiredString(_ key: String) throws -> String {
        guard let string = try string(key) else { throw LibraryError.invalidArgument("\(key) is required.") }
        return string
    }

    func requiredStrings(_ key: String) throws -> [String] {
        guard let array = values[key]?.arrayValue else {
            throw LibraryError.invalidArgument("\(key) must be an array of strings.")
        }
        return try array.map { element in
            guard let string = element.stringValue else {
                throw LibraryError.invalidArgument("\(key) must contain only strings.")
            }
            return string
        }
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let int = value.intValue else { throw LibraryError.invalidArgument("\(key) must be an integer.") }
        return int
    }

    func requiredInt(_ key: String) throws -> Int {
        guard let int = try int(key) else { throw LibraryError.invalidArgument("\(key) is required.") }
        return int
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard let bool = values[key]?.boolValue else {
            throw LibraryError.invalidArgument("\(key) must be true or false.")
        }
        return bool
    }

    func requiredUUID(_ key: String) throws -> UUID {
        let string = try requiredString(key)
        guard let id = UUID(uuidString: string) else {
            throw LibraryError.invalidArgument("\(key) must be an id returned by littlelog.")
        }
        return id
    }
}

private extension JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        .object((objectValue ?? [:]).merging(other) { _, new in new })
    }
}
