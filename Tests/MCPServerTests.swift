import Foundation
import SwiftData
import Testing
@testable import littlelog

@MainActor
struct MCPServerTests {
    static let relayHeaders = [
        "host": "relay.example",
        "x-forwarded-proto": "https",
        "x-forwarded-prefix": "/d/0123456789abcdef0123456789abcdef",
    ]

    private let container: ModelContainer
    private let library: Library
    private let server: MCPServer
    private let token: String

    init() throws {
        container = try Persistence.makeInMemoryContainer()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-16T06:00:00Z"))
        library = Library(context: container.mainContext, calendar: calendar, now: { now })
        // A signed-in app, as if ChatGPT had completed the OAuth flow (covered in OAuthTests).
        let store = OAuthStore(url: nil)
        let verifier = "test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
        let client = try store.register(name: "ChatGPT", redirectURIs: ["https://chatgpt.com/callback"])
        let code = try store.issueCode(clientID: client.id, redirectURI: "https://chatgpt.com/callback", codeChallenge: OAuthStore.s256(verifier))
        token = try store.exchange(code: code, clientID: client.id, redirectURI: "https://chatgpt.com/callback", codeVerifier: verifier).accessToken
        server = MCPServer(library: library, oauth: OAuthEndpoints(store: store) { _, _ in true })
    }

    // MARK: Helpers

    private func request(_ method: String, _ path: String, body: Data = Data(), headers: [String: String] = [:]) -> HTTPRequest {
        var all = Self.relayHeaders
        all["content-type"] = "application/json"
        all["authorization"] = "Bearer \(token)"
        all.merge(headers) { _, new in new }
        return HTTPRequest(method: method, path: path, headers: all.filter { !$0.value.isEmpty }, body: body)
    }

    private func post(_ body: JSONValue, headers: [String: String] = [:]) async throws -> HTTPResponse {
        await server.respond(to: request("POST", "/mcp", body: try body.encoded(), headers: headers))
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
            "clientInfo": ["name": "chatgpt", "version": "1"],
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

    @Test func everyAdvertisedToolIsCallable() async throws {
        let tools = try #require(try await rpc("tools/list")["result"]?["tools"]?.arrayValue)
        for tool in tools {
            let name = try #require(tool["name"]?.stringValue)
            // Empty arguments are invalid for most tools; what matters is the tool exists.
            let reply = try await rpc("tools/call", ["name": .string(name), "arguments": [:]])
            #expect(reply["error"] == nil, "\(name) is advertised but not callable")
        }
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
        let parse = await server.respond(to: request("POST", "/mcp", body: Data("{nope".utf8)))
        #expect(parse.status == 400)
        #expect(try JSONValue.decode(parse.body)["error"]?["code"] == -32700)

        let batch = try await post([["jsonrpc": "2.0", "id": 1, "method": "ping"]])
        #expect(batch.status == 400)
    }

    // MARK: Security

    @Test func requiresASignedInToken() async throws {
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        let missing = try await post(ping, headers: ["authorization": ""])
        #expect(missing.status == 401)
        #expect(missing.headers["WWW-Authenticate"]?.contains("https://relay.example/d/0123456789abcdef0123456789abcdef/.well-known/oauth-protected-resource") == true)
        #expect(try await post(ping, headers: ["authorization": "Bearer wrong"]).status == 401)
        #expect(try await post(ping).status == 200)
    }

    @Test func onlyRequestsThroughTheRelayAreServed() async throws {
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(try await post(ping, headers: ["x-forwarded-proto": ""]).status == 403)
        #expect(try await post(ping, headers: ["x-forwarded-prefix": "/d/../../evil"]).status == 403)
        #expect(try await post(ping, headers: ["host": ""]).status == 403)
    }

    @Test func onlyPostOnTheMCPPath() async throws {
        #expect(await server.respond(to: request("GET", "/mcp")).status == 405)
        #expect(await server.respond(to: request("POST", "/other")).status == 404)
        #expect(try await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["mcp-protocol-version": "2000-01-01"]).status == 400)
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

        let stored = try library.tasks(on: "2026-10-16")
        #expect(stored.allSatisfy { $0.addedByAssistant })
    }

    @Test func addingIsIdempotentAndSkipsDuplicates() async throws {
        try library.addTask("Buy milk", on: library.dayKey)
        let result = try await call("add_tasks", ["tasks": ["buy  MILK", "Call mom", "call mom", "  "]])
        #expect(result.structured["added"]?.arrayValue?.map { $0["text"] } == ["Call mom"])
        #expect(result.structured["skipped"]?.arrayValue?.count == 3)
        #expect(try library.tasks(on: "2026-10-16").map(\.text) == ["Buy milk", "Call mom"])
    }

    @Test func tasksForTomorrowAndExplicitDates() async throws {
        _ = try await call("add_tasks", ["tasks": ["Plan trip"], "date": "tomorrow"])
        _ = try await call("add_tasks", ["tasks": ["Dentist"], "date": "2026-10-20"])
        #expect(try library.tasks(on: "2026-10-17").map(\.text) == ["Plan trip"])
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
        #expect(try library.tasks(on: "2026-10-16").map(\.text) == ["c", "b2"])

        // The user can undo an assistant's deletion from the panel.
        library.undoManager.undo()
        #expect(try library.tasks(on: "2026-10-16").count == 3)
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
