import Foundation
import Testing
@testable import littlelog

/// The relay wire format, checked against the same fixtures `relay/contract/check.mjs` uses.
/// A change to either side that the other doesn't match fails one of the two checks.
@MainActor
struct RelayContractTests {
    private final class BundleToken {}

    private let fixtures: JSONValue

    init() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "frames", withExtension: "json"))
        fixtures = try JSONValue.decode(try Data(contentsOf: url))
    }

    @Test func requestFramesDecodeToTheRequestTheRelayMeant() throws {
        let frameJSON = try #require(fixtures["request"]?["frame"])
        let frame = try JSONDecoder().decode(RelayRequestFrame.self, from: try frameJSON.encoded())
        let request = try #require(frame.request)
        let input = try #require(fixtures["request"]?["input"])

        #expect(request.method == input["method"]?.stringValue)
        #expect(request.path == input["path"]?.stringValue)
        #expect(request.query == ["x": "1"])
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("authorization") == "Bearer abc")
        #expect(request.header("cookie") == nil)
        #expect(String(decoding: request.body, as: UTF8.self) == input["body"]?.stringValue)
    }

    @Test func theFramesForwardedHeadersBuildThePublicAddress() throws {
        let frameJSON = try #require(fixtures["request"]?["frame"])
        let frame = try JSONDecoder().decode(RelayRequestFrame.self, from: try frameJSON.encoded())
        let request = try #require(frame.request)
        let device = try #require(fixtures["device"]?.stringValue)
        #expect(MCPServer.baseURL(for: request) == "https://relay.example/d/\(device)")
    }

    @Test func responsesEncodeToTheFrameTheRelayExpects() throws {
        let mac = try #require(fixtures["response"]?["mac"])
        let headers = try #require(mac["headers"]?.objectValue?.compactMapValues { $0.stringValue })
        let response = HTTPResponse(
            status: try #require(mac["status"]?.intValue),
            headers: headers,
            body: Data(try #require(mac["body"]?.stringValue).utf8)
        )
        let frame = RelayResponseFrame(id: try #require(mac["id"]?.stringValue), response: response)

        let encoded = try JSONValue.decode(try JSONEncoder().encode(frame))
        #expect(encoded == fixtures["response"]?["frame"])
    }

    @Test func deviceIdentitiesUseTheContractedIdShape() throws {
        let device = try #require(fixtures["device"]?.stringValue)
        #expect(device.wholeMatch(of: /[0-9a-f]{32}/) != nil)
        let created = try DeviceIdentity.loadOrCreate(at: FileManager.default.temporaryDirectory.appending(path: "littlelog-contract-\(UUID().uuidString).json"))
        #expect(created.id.count == device.count)
    }
}
