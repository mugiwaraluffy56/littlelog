import Foundation
import Testing
@testable import littlelog

/// The full sign-in ChatGPT performs: discovery → registration → authorize (approved on the Mac)
/// → token exchange with PKCE → MCP calls with the access token → refresh.
@MainActor
struct OAuthTests {
    /// This Mac's public address through the relay.
    private let publicBase = "relay.example/d/0123456789abcdef0123456789abcdef"
    private let redirect = "https://chatgpt.com/connector_platform_oauth_redirect"
    private let verifier = "verifier-0123456789-abcdefghijklmnopqrstuvwxyz-ABCDEFG"

    private func makeServer(approve: Bool = true) throws -> (MCPServer, OAuthStore) {
        let container = try Persistence.makeInMemoryContainer()
        let library = Library(context: container.mainContext)
        let store = OAuthStore(url: nil)
        let oauth = OAuthEndpoints(store: store) { _, _ in approve }
        return (MCPServer(library: library, oauth: oauth), store)
    }

    private func request(_ method: String, _ target: String, body: Data = Data(), headers: [String: String] = [:]) -> HTTPRequest {
        let parts = target.split(separator: "?", maxSplits: 1)
        var all = MCPServerTests.relayHeaders
        all.merge(headers) { _, new in new }
        return HTTPRequest(
            method: method,
            path: String(parts[0]),
            query: parts.count > 1 ? FormEncoding.decode(String(parts[1])) : [:],
            headers: all,
            body: body
        )
    }

    private func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func register(_ server: MCPServer) async throws -> String {
        let body = try (["client_name": "ChatGPT", "redirect_uris": [.string(redirect)]] as JSONValue).encoded()
        let response = await server.respond(to: request("POST", "/oauth/register", body: body, headers: ["content-type": "application/json"]))
        #expect(response.status == 201)
        return try #require(try JSONValue.decode(response.body)["client_id"]?.stringValue)
    }

    private func authorize(_ server: MCPServer, clientID: String, challenge: String? = nil) async -> HTTPResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: challenge ?? OAuthStore.s256(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: "xyz"),
        ]
        return await server.respond(to: request("GET", "/oauth/authorize?\(components.percentEncodedQuery ?? "")"))
    }

    private func code(from response: HTTPResponse) throws -> String {
        let location = try #require(response.headers["Location"])
        let items = try #require(URLComponents(string: location)?.queryItems)
        #expect(items.first { $0.name == "state" }?.value == "xyz")
        return try #require(items.first { $0.name == "code" }?.value)
    }

    private func exchange(_ server: MCPServer, clientID: String, code: String, verifier: String? = nil) async -> HTTPResponse {
        await server.respond(to: request("POST", "/oauth/token", body: form([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirect,
            "code_verifier": verifier ?? self.verifier,
        ]), headers: ["content-type": "application/x-www-form-urlencoded"]))
    }

    private func ping(_ server: MCPServer, token: String) async throws -> HTTPResponse {
        await server.respond(to: request("POST", "/mcp", body: try (["jsonrpc": "2.0", "id": 1, "method": "ping"] as JSONValue).encoded(), headers: [
            "content-type": "application/json",
            "authorization": "Bearer \(token)",
        ]))
    }

    // MARK: Tests

    @Test func unauthenticatedMCPCallPointsToMetadata() async throws {
        let (server, _) = try makeServer()
        let response = await server.respond(to: request("POST", "/mcp", body: Data("{}".utf8), headers: ["content-type": "application/json"]))
        #expect(response.status == 401)
        #expect(response.headers["WWW-Authenticate"]?.contains("resource_metadata=\"https://\(publicBase)/.well-known/oauth-protected-resource\"") == true)
    }

    @Test func discoveryDocumentsUseThePublicURL() async throws {
        let (server, _) = try makeServer()
        let resource = try JSONValue.decode(await server.respond(to: request("GET", "/.well-known/oauth-protected-resource")).body)
        #expect(resource["resource"] == .string("https://\(publicBase)/mcp"))
        #expect(resource["authorization_servers"] == [.string("https://\(publicBase)")])

        let metadata = try JSONValue.decode(await server.respond(to: request("GET", "/.well-known/oauth-authorization-server")).body)
        #expect(metadata["issuer"] == .string("https://\(publicBase)"))
        #expect(metadata["registration_endpoint"] == .string("https://\(publicBase)/oauth/register"))
        #expect(metadata["code_challenge_methods_supported"] == ["S256"])
    }

    @Test func fullSignInThenToolsThenRefresh() async throws {
        let (server, _) = try makeServer()
        let clientID = try await register(server)
        let authorized = await authorize(server, clientID: clientID)
        #expect(authorized.status == 302)
        let code = try code(from: authorized)

        let tokens = try JSONValue.decode(await exchange(server, clientID: clientID, code: code).body)
        let access = try #require(tokens["access_token"]?.stringValue)
        let refresh = try #require(tokens["refresh_token"]?.stringValue)
        #expect(tokens["token_type"] == "Bearer")
        #expect(try await ping(server, token: access).status == 200)

        // Codes are single use.
        #expect(await exchange(server, clientID: clientID, code: code).status == 400)

        // Refresh rotates: the new token works, the old refresh token doesn't.
        let refreshBody = form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        let refreshed = try JSONValue.decode(await server.respond(to: request("POST", "/oauth/token", body: refreshBody)).body)
        let newAccess = try #require(refreshed["access_token"]?.stringValue)
        #expect(try await ping(server, token: newAccess).status == 200)
        #expect(await server.respond(to: request("POST", "/oauth/token", body: refreshBody)).status == 400)
    }

    @Test func wrongPKCEVerifierIsRejected() async throws {
        let (server, _) = try makeServer()
        let clientID = try await register(server)
        let code = try code(from: await authorize(server, clientID: clientID))
        let response = await exchange(server, clientID: clientID, code: code, verifier: "not-the-verifier-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        #expect(response.status == 400)
        #expect(try JSONValue.decode(response.body)["error"] == "invalid_grant")
    }

    @Test func denyingOnTheMacRedirectsWithAccessDenied() async throws {
        let (server, _) = try makeServer(approve: false)
        let clientID = try await register(server)
        let response = await authorize(server, clientID: clientID)
        let location = try #require(response.headers["Location"])
        #expect(location.hasPrefix(redirect))
        #expect(location.contains("error=access_denied"))
        #expect(!location.contains("code="))
    }

    @Test func unregisteredRedirectsAreNeverFollowed() async throws {
        let (server, _) = try makeServer()
        let clientID = try await register(server)
        let evil = await server.respond(to: request("GET", "/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=https%3A%2F%2Fevil.example%2Fcb&code_challenge=abc&code_challenge_method=S256"))
        #expect(evil.status == 400)
        #expect(evil.headers["Location"] == nil)

        let badRegistration = try (["redirect_uris": ["http://evil.example/cb"]] as JSONValue).encoded()
        #expect(await server.respond(to: request("POST", "/oauth/register", body: badRegistration)).status == 400)
    }

    @Test func registrationRejectsNonStringRedirects() async throws {
        let (server, _) = try makeServer()
        let body = try ([
            "redirect_uris": [.string(redirect), 42],
        ] as JSONValue).encoded()
        let response = await server.respond(to: request("POST", "/oauth/register", body: body))
        #expect(response.status == 400)
        #expect(try JSONValue.decode(response.body)["error"] == "invalid_client_metadata")
    }

    @Test func pkceIsRequired() async throws {
        let (server, _) = try makeServer()
        let clientID = try await register(server)
        let response = await server.respond(to: request("GET", "/oauth/authorize?response_type=code&client_id=\(clientID)&redirect_uri=\(redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")&state=xyz"))
        #expect(response.headers["Location"]?.contains("error=invalid_request") == true)
    }

    @Test func revokingDisconnectsSignedInApps() async throws {
        let (server, store) = try makeServer()
        let clientID = try await register(server)
        let code = try code(from: await authorize(server, clientID: clientID))
        let access = try #require(try JSONValue.decode(await exchange(server, clientID: clientID, code: code).body)["access_token"]?.stringValue)
        #expect(store.connectedClients.map(\.name) == ["ChatGPT"])

        try store.revokeAll()
        #expect(try await ping(server, token: access).status == 401)
        #expect(store.connectedClients.isEmpty)
    }

    @Test func requestsNotFromTheRelayAreRefused() async throws {
        let (server, _) = try makeServer()
        let direct = HTTPRequest(method: "GET", path: "/.well-known/oauth-protected-resource", headers: ["host": "evil.example"], body: Data())
        #expect(await server.respond(to: direct).status == 403)
    }

    @Test func persistsAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "littlelog-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "oauth.json")

        let first = OAuthStore(url: url)
        let client = try first.register(name: "ChatGPT", redirectURIs: [redirect])
        let code = try first.issueCode(clientID: client.id, redirectURI: redirect, codeChallenge: OAuthStore.s256(verifier))
        let pair = try first.exchange(code: code, clientID: client.id, redirectURI: redirect, codeVerifier: verifier)

        let second = OAuthStore(url: url)
        #expect(second.isValidAccessToken(pair.accessToken))
        #expect(second.client(id: client.id)?.name == "ChatGPT")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains(pair.accessToken))   // only hashes are stored
    }
}
