import Foundation
import Testing
@testable import littlelog

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

struct FormEncodingTests {
    @Test func decodesQueryAndFormStrings() {
        let values = FormEncoding.decode("a=1&b=two+words&c=%2Fpath%3Fx&a=ignored&empty=&=skip")
        #expect(values == ["a": "1", "b": "two words", "c": "/path?x", "empty": ""])
    }
}

@MainActor
struct RelayTests {
    @Test func requestFramesBecomeHTTPRequests() throws {
        let json = """
        {"type":"request","id":"r1","method":"POST","path":"/mcp","query":"x=1",
         "headers":{"Content-Type":"application/json","X-Forwarded-Proto":"https"},
         "body":"\(Data("{}".utf8).base64EncodedString())"}
        """
        let frame = try JSONDecoder().decode(RelayRequestFrame.self, from: Data(json.utf8))
        let request = try #require(frame.request)
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.query == ["x": "1"])
        #expect(request.header("content-type") == "application/json")
        #expect(request.headers["x-forwarded-proto"] == "https")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func malformedFramesAreRejected() throws {
        let badBody = RelayRequestFrame(type: "request", id: "1", method: "GET", path: "/", query: "", headers: [:], body: "%%%")
        #expect(badBody.request == nil)
        let wrongType = RelayRequestFrame(type: "response", id: "1", method: "GET", path: "/", query: "", headers: [:], body: "")
        #expect(wrongType.request == nil)
    }

    @Test func responsesAreEncodedForTheRelay() throws {
        let frame = RelayResponseFrame(id: "r1", response: .redirect(to: "https://chatgpt.com/cb?code=1"))
        let json = try JSONValue.decode(try JSONEncoder().encode(frame))
        #expect(json["type"] == "response")
        #expect(json["id"] == "r1")
        #expect(json["status"] == 302)
        #expect(json["headers"]?["Location"] == "https://chatgpt.com/cb?code=1")
    }

    @Test func connectURLs() {
        #expect(AssistantAccess.connectURL(for: "https://relay.example")?.absoluteString == "wss://relay.example/connect")
        #expect(AssistantAccess.connectURL(for: "http://127.0.0.1:8799")?.absoluteString == "ws://127.0.0.1:8799/connect")
        #expect(AssistantAccess.connectURL(for: "http://relay.example") == nil)
        #expect(AssistantAccess.connectURL(for: "ftp://relay.example") == nil)
    }

    @Test func deviceIdentityIsCreatedOnceAndKeptPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "littlelog-device-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "relay-device.json")

        let first = try DeviceIdentity.loadOrCreate(at: url)
        #expect(first.id.wholeMatch(of: /[0-9a-f]{32}/) != nil)
        #expect(first.secret.count >= 43)
        #expect(try DeviceIdentity.loadOrCreate(at: url) == first)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
