import Foundation
import Testing
@testable import littlelog

struct HTTPParserTests {
    private func parse(_ raw: String) -> HTTPParser.Result {
        HTTPParser.parse(Data(raw.utf8))
    }

    @Test func parsesARequestWithBody() throws {
        let result = parse("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:48177\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}NEXT")
        guard case .request(let request, let remainder) = result else {
            Issue.record("expected a request, got \(result)")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.header("HOST") == "127.0.0.1:48177")
        #expect(request.body == Data("{}".utf8))
        #expect(remainder == Data("NEXT".utf8))
        #expect(request.keepsAlive)
    }

    @Test func waitsForTheWholeBody() {
        guard case .incomplete = parse("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"") else {
            Issue.record("expected incomplete")
            return
        }
        guard case .incomplete = parse("POST /mcp HTTP/1.1\r\nHost: x") else {
            Issue.record("expected incomplete headers")
            return
        }
    }

    @Test func rejectsBadInput() {
        func status(_ raw: String) -> Int? {
            if case .invalid(let response) = parse(raw) { return response.status }
            return nil
        }
        #expect(status("GARBAGE\r\n\r\n") == 400)
        #expect(status("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == 400)
        #expect(status("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == 501)
        #expect(status("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") == 413)
        #expect(status("POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)) == 431)
    }

    @Test func connectionCloseIsHonoured() throws {
        guard case .request(let request, _) = parse("GET /mcp HTTP/1.1\r\nConnection: close\r\n\r\n") else {
            Issue.record("expected a request")
            return
        }
        #expect(!request.keepsAlive)
    }

    @Test func serializesResponses() {
        let data = HTTPResponse.text("hi", status: 401, headers: ["WWW-Authenticate": "Bearer"]).serialized(keepAlive: false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\nhi"))
    }
}

struct DayKeyResolveTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T20:00:00Z")!

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        return calendar
    }

    @Test func relativeWordsUseTheLocalDay() throws {
        // 20:00 UTC is already 01:30 on the 17th in Kolkata.
        let calendar = try calendar()
        #expect(DayKey.resolve(nil, now: now, calendar: calendar) == "2026-10-17")
        #expect(DayKey.resolve(" Today ", now: now, calendar: calendar) == "2026-10-17")
        #expect(DayKey.resolve("tomorrow", now: now, calendar: calendar) == "2026-10-18")
        #expect(DayKey.resolve("yesterday", now: now, calendar: calendar) == "2026-10-16")
    }

    @Test func explicitDatesMustBeReal() throws {
        let calendar = try calendar()
        #expect(DayKey.resolve("2026-12-31", now: now, calendar: calendar) == "2026-12-31")
        #expect(DayKey.resolve("2028-02-29", now: now, calendar: calendar) == "2028-02-29")
        #expect(DayKey.resolve("2026-02-30", now: now, calendar: calendar) == nil)
        #expect(DayKey.resolve("2026-1-5", now: now, calendar: calendar) == nil)
        #expect(DayKey.resolve("next friday", now: now, calendar: calendar) == nil)
    }
}

struct CodexConfigTests {
    private let block = """
    [mcp_servers.littlelog]
    url = "http://127.0.0.1:48177/mcp"
    """

    @Test func appendsToAnExistingConfigWithoutTouchingIt() {
        let existing = """
        model = "gpt-5"
        # my servers
        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"
        """
        let merged = CodexConfig.merging(existing, block: block)
        #expect(merged == existing + "\n\n" + block + "\n")
    }

    @Test func replacesItsOwnTablesOnly() {
        let existing = """
        [mcp_servers.littlelog]
        url = "http://old"
        http_headers = { Authorization = "Bearer old" }

        [mcp_servers.littlelog.tools.delete_task]
        approval_mode = "prompt"

        [mcp_servers.littlelog_other]
        url = "keep"

        [profiles.default]
        model = "x"
        """
        let merged = CodexConfig.merging(existing, block: block)
        #expect(!merged.contains("Bearer old"))
        #expect(!merged.contains("http://old"))
        #expect(merged.contains("[mcp_servers.littlelog_other]\nurl = \"keep\""))
        #expect(merged.contains("[profiles.default]\nmodel = \"x\""))
        #expect(merged.hasSuffix(block + "\n"))
        #expect(merged.components(separatedBy: "[mcp_servers.littlelog]").count == 2)
    }

    @Test func handlesQuotedHeadersAndEmptyFiles() {
        let quoted = "[mcp_servers.\"littlelog\"]\nurl = \"old\"\n[other]\na = 1"
        #expect(CodexConfig.merging(quoted, block: block) == "[other]\na = 1\n\n" + block + "\n")
        #expect(CodexConfig.merging("", block: block) == block + "\n")
    }
}

@MainActor
struct AccessTokenStoreTests {
    @Test func createsPersistsAndReplacesTokens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "littlelog-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccessTokenStore(url: directory.appending(path: "token"))

        let first = try store.loadOrCreate()
        #expect(first.count >= 43)
        #expect(!first.contains("+") && !first.contains("/") && !first.contains("="))
        #expect(try store.loadOrCreate() == first)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let second = try store.replace()
        #expect(second != first)
        #expect(try store.loadOrCreate() == second)
    }
}
