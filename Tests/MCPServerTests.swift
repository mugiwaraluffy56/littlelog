import Foundation
import SwiftData
import Testing
@testable import littlelog

@MainActor
struct MCPServerTests {
    private let token = "test-token-0123456789abcdefghijklmnopqrstuv"
    private let container: ModelContainer
    private let state: AppState
    private let server: MCPServer

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T06:00:00Z"))
        state = AppState(context: container.mainContext, calendar: calendar, now: { now })
        let token = self.token
        let oauth = OAuthEndpoints(store: OAuthStore(url: nil)) { _, _ in true }
        server = MCPServer(state: state, token: { token }, oauth: oauth)
    }

    // MARK: Helpers

    private func post(_ body: JSONValue, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var all = [
            "host": "127.0.0.1:48177",
            "content-type": "application/json",
            "authorization": "Bearer \(token)",
        ]
        all.merge(headers.mapKeys { $0.lowercased() }) { _, new in new }
        let request = HTTPRequest(method: "POST", path: "/mcp", version: "HTTP/1.1", headers: all, body: try body.encoded())
        return await server.respond(to: request)
    }

    private func rpc(_ method: String, _ params: JSONValue = [:], id: JSONValue = 1) async throws -> JSONValue {
        let response = try await post(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
        #expect(response.status == 200)
        return try JSONValue.decode(response.body)
    }

    private func call(_ tool: String, _ arguments: JSONValue = [:]) async throws -> (structured: JSONValue, isError: Bool) {
        let reply = try await rpc("tools/call", ["name": .string(tool), "arguments": arguments])
        let result = try #require(reply["result"])
        return (try #require(result["structuredContent"]), result["isError"]?.boolValue ?? false)
    }

    // MARK: Protocol

    @Test func initializeNegotiatesVersionAndAdvertisesTools() async throws {
        let reply = try await rpc("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "codex", "version": "1"],
        ])
        #expect(reply["id"] == 1)
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["serverInfo"]?["name"] == "littlelog")
        #expect(result["instructions"]?.stringValue?.contains("2026-10-16") == true)
    }

    @Test func unknownProtocolVersionFallsBackToLatest() async throws {
        let reply = try await rpc("initialize", ["protocolVersion": "1999-01-01"])
        #expect(reply["result"]?["protocolVersion"] == .string(MCPServer.supportedVersions[0]))
    }

    @Test func notificationsAreAcceptedWithoutBody() async throws {
        let response = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func stringIDsRoundTrip() async throws {
        let reply = try await rpc("ping", id: "abc-1")
        #expect(reply["id"] == "abc-1")
        #expect(reply["result"] == [:])
    }

    @Test func toolsListHasAnnotatedTools() async throws {
        let tools = try #require(try await rpc("tools/list")["result"]?["tools"]?.arrayValue)
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in tool["name"]?.stringValue.map { ($0, tool) } })
        #expect(Set(byName.keys) == [
            "list_tasks", "add_tasks", "set_task_completed", "update_task",
            "move_task", "delete_task", "search_notes", "read_note",
        ])
        #expect(byName["list_tasks"]?["annotations"]?["readOnlyHint"] == true)
        #expect(byName["delete_task"]?["annotations"]?["destructiveHint"] == true)
        #expect(byName["add_tasks"]?["inputSchema"]?["required"] == ["tasks"])
    }

    @Test func unknownMethodAndToolAreJSONRPCErrors() async throws {
        #expect(try await rpc("resources/list")["error"]?["code"] == -32601)
        #expect(try await rpc("tools/call", ["name": "nope"])["error"]?["code"] == -32602)
    }

    @Test func malformedJSONAndBatchesAreRejected() async throws {
        let request = HTTPRequest(
            method: "POST", path: "/mcp", version: "HTTP/1.1",
            headers: ["host": "localhost:48177", "content-type": "application/json", "authorization": "Bearer \(token)"],
            body: Data("{nope".utf8)
        )
        let parse = await server.respond(to: request)
        #expect(parse.status == 400)
        #expect(try JSONValue.decode(parse.body)["error"]?["code"] == -32700)

        let batch = try await post([["jsonrpc": "2.0", "id": 1, "method": "ping"]])
        #expect(batch.status == 400)
    }

    // MARK: Security

    @Test func requiresTheBearerToken() async throws {
        #expect(try await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["authorization": ""]).status == 401)
        #expect(try await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["authorization": "Bearer wrong"]).status == 401)
        #expect(try await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["authorization": "Bearer \(token)"]).status == 200)
    }

    @Test func rejectsForeignOriginsAndHosts() async throws {
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(try await post(ping, headers: ["origin": "https://evil.example"]).status == 403)
        #expect(try await post(ping, headers: ["host": "evil.example:48177"]).status == 403)
        #expect(try await post(ping, headers: ["origin": "http://localhost:3000"]).status == 200)
    }

    @Test func onlyPostOnTheMCPPath() async throws {
        let base = ["host": "127.0.0.1:48177", "authorization": "Bearer \(token)"]
        let get = await server.respond(to: HTTPRequest(method: "GET", path: "/mcp", version: "HTTP/1.1", headers: base, body: Data()))
        #expect(get.status == 405)
        let other = await server.respond(to: HTTPRequest(method: "POST", path: "/other", version: "HTTP/1.1", headers: base, body: Data()))
        #expect(other.status == 404)
        #expect(try await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["mcp-protocol-version": "2000-01-01"]).status == 400)
    }

    @Test func constantTimeComparison() {
        #expect(MCPServer.constantTimeEquals("abc", "abc"))
        #expect(!MCPServer.constantTimeEquals("abc", "abd"))
        #expect(!MCPServer.constantTimeEquals("abc", "abcd"))
        #expect(!MCPServer.constantTimeEquals("", ""))
    }

    // MARK: Tools

    @Test func addThenListTasks() async throws {
        let added = try await call("add_tasks", ["tasks": ["Finish chapter 4", "Review PR"]])
        #expect(!added.isError)
        #expect(added.structured["added"]?.arrayValue?.count == 2)
        #expect(added.structured["relative"] == "today")

        let listed = try await call("list_tasks")
        let tasks = try #require(listed.structured["tasks"]?.arrayValue)
        #expect(tasks.map { $0["text"] } == ["Finish chapter 4", "Review PR"])
        #expect(tasks.allSatisfy { $0["added_by"] == "assistant" })
        #expect(listed.structured["remaining"] == 2)

        let stored = try state.tasks(on: "2026-10-16")
        #expect(stored.allSatisfy { $0.addedByAssistant })
    }

    @Test func addingIsIdempotentAndSkipsDuplicates() async throws {
        state.newTaskDraft = "Buy milk"
        state.addTask()
        let result = try await call("add_tasks", ["tasks": ["buy  MILK", "Call mom", "call mom", "  "]])
        #expect(result.structured["added"]?.arrayValue?.map { $0["text"] } == ["Call mom"])
        #expect(result.structured["skipped"]?.arrayValue?.count == 3)
        #expect(try state.tasks(on: "2026-10-16").map(\.text) == ["Buy milk", "Call mom"])
    }

    @Test func tasksForTomorrowAndExplicitDates() async throws {
        _ = try await call("add_tasks", ["tasks": ["Plan trip"], "date": "tomorrow"])
        _ = try await call("add_tasks", ["tasks": ["Dentist"], "date": "2026-10-20"])
        #expect(try state.tasks(on: "2026-10-17").map(\.text) == ["Plan trip"])
        #expect(try await call("list_tasks", ["date": "2026-10-20"]).structured["tasks"]?.arrayValue?.count == 1)
        #expect(try await call("list_tasks").structured["tasks"]?.arrayValue?.isEmpty == true)

        let invalid = try await call("list_tasks", ["date": "next week"])
        #expect(invalid.isError)
        #expect(invalid.structured["error"]?.stringValue?.contains("YYYY-MM-DD") == true)
    }

    @Test func completeEditMoveAndDelete() async throws {
        _ = try await call("add_tasks", ["tasks": ["a", "b", "c"]])
        let ids = try #require(try await call("list_tasks").structured["tasks"]?.arrayValue?.compactMap { $0["id"] })

        let done = try await call("set_task_completed", ["id": ids[0], "completed": true])
        #expect(done.structured["task"]?["completed"] == true)

        let edited = try await call("update_task", ["id": ids[1], "text": "  b2 "])
        #expect(edited.structured["task"]?["text"] == "b2")
        #expect(try await call("update_task", ["id": ids[1], "text": " "]).isError)

        let moved = try await call("move_task", ["id": ids[2], "position": 0])
        #expect(moved.structured["tasks"]?.arrayValue?.map { $0["text"] } == ["c", "a", "b2"])

        let deleted = try await call("delete_task", ["id": ids[0]])
        #expect(deleted.structured["deleted"]?["text"] == "a")
        #expect(try state.tasks(on: "2026-10-16").map(\.text) == ["c", "b2"])

        // The user can undo an assistant's deletion from the panel.
        state.undoManager.undo()
        #expect(try state.tasks(on: "2026-10-16").count == 3)
    }

    @Test func badArgumentsComeBackAsToolErrors() async throws {
        #expect(try await call("set_task_completed", ["id": "not-a-uuid", "completed": true]).isError)
        #expect(try await call("set_task_completed", ["id": .string(UUID().uuidString), "completed": true]).isError)
        #expect(try await call("add_tasks", ["tasks": "one"]).isError)
        #expect(try await call("add_tasks", ["tasks": []]).isError)
        #expect(try await call("search_notes", ["limit": 500]).isError)
    }

    @Test func notesAreSearchableAndReadOnly() async throws {
        let context = container.mainContext
        let grocery = Note(title: "Groceries", content: "eggs and milk", updatedAt: .now)
        context.insert(grocery)
        context.insert(Note(title: "Ideas", content: "an app for notes", updatedAt: .now.addingTimeInterval(-60)))
        context.insert(Note(title: " ", content: ""))
        try context.save()

        let found = try await call("search_notes", ["query": "milk"])
        #expect(found.structured["notes"]?.arrayValue?.map { $0["title"] } == ["Groceries"])
        #expect(try await call("search_notes").structured["notes"]?.arrayValue?.count == 2)

        let read = try await call("read_note", ["id": .string(grocery.id.uuidString)])
        #expect(read.structured["content"] == "eggs and milk")

        let tools = try #require(try await rpc("tools/list")["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(!tools.contains { $0.contains("note") && !["search_notes", "read_note"].contains($0) })
    }

    @Test func toolResultsIncludeTextContent() async throws {
        let reply = try await rpc("tools/call", ["name": "list_tasks", "arguments": [:]])
        let content = try #require(reply["result"]?["content"]?.arrayValue?.first)
        #expect(content["type"] == "text")
        let text = try #require(content["text"]?.stringValue)
        #expect(try JSONValue.decode(Data(text.utf8))["date"] == "2026-10-16")
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(map { (transform($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
    }
}
