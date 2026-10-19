import Foundation

/// A stateless Model Context Protocol server over Streamable HTTP (spec 2025-11-25): each POST
/// carries one JSON-RPC message and gets a single JSON response. There are no server-initiated
/// messages, so GET (SSE) is declined with 405 as the spec allows.
final class MCPServer {
    static let endpointPath = "/mcp"
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let tools: AssistantTools
    private let library: Library
    private let oauth: OAuthEndpoints

    init(library: Library, oauth: OAuthEndpoints) {
        self.library = library
        self.tools = AssistantTools(library: library)
        self.oauth = oauth
    }

    /// Every path this Mac serves. Sign-in and MCP share this one table.
    private enum Route {
        case protectedResource
        case authorizationServer
        case register
        case authorize
        case token
        case mcp

        init?(path: String) {
            switch path {
            case "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp":
                self = .protectedResource
            case "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp",
                 "/.well-known/openid-configuration":
                self = .authorizationServer
            case "/oauth/register": self = .register
            case "/oauth/authorize": self = .authorize
            case "/oauth/token": self = .token
            case MCPServer.endpointPath: self = .mcp
            default: return nil
            }
        }

        var method: String {
            switch self {
            case .protectedResource, .authorizationServer, .authorize: "GET"
            case .register, .token, .mcp: "POST"
            }
        }
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let base = Self.baseURL(for: request) else {
            return .text("Requests must come through the littlelog relay", status: 403)
        }
        guard let route = Route(path: request.path) else {
            return .text("Not found", status: 404)
        }
        guard request.method == route.method else {
            return .text("Use \(route.method)", status: 405, headers: ["Allow": route.method])
        }
        switch route {
        case .protectedResource: return oauth.protectedResourceMetadata(baseURL: base)
        case .authorizationServer: return oauth.authorizationServerMetadata(baseURL: base)
        case .register: return oauth.register(request)
        case .authorize: return await oauth.authorize(request)
        case .token: return oauth.token(request)
        case .mcp: return respondToMCP(request, base: base)
        }
    }

    private func respondToMCP(_ request: HTTPRequest, base: String) -> HTTPResponse {
        // Every MCP call needs a sign-in that was approved on this Mac.
        guard let token = Self.bearerToken(request.header("authorization")), oauth.store.isValidAccessToken(token) else {
            return .text("Missing or invalid access token", status: 401, headers: [
                "WWW-Authenticate": "Bearer realm=\"littlelog\", resource_metadata=\"\(base)/.well-known/oauth-protected-resource\"",
            ])
        }
        if let version = request.header("mcp-protocol-version"), !Self.supportedVersions.contains(version) {
            return .text("Unsupported MCP-Protocol-Version \(version)", status: 400)
        }
        guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else {
            return .text("Content-Type must be application/json", status: 415)
        }
        return handle(body: request.body)
    }

    // MARK: JSON-RPC

    private func handle(body: Data) -> HTTPResponse {
        let message: JSONValue
        do {
            message = try JSONValue.decode(body)
        } catch {
            return .json(Self.error(id: .null, code: -32700, message: "Parse error"), status: 400)
        }
        guard case .object(let object) = message else {
            return .json(Self.error(id: .null, code: -32600, message: "Send one JSON-RPC message per request"), status: 400)
        }
        guard object["jsonrpc"] == "2.0" else {
            return .json(Self.error(id: object["id"] ?? .null, code: -32600, message: "jsonrpc must be \"2.0\""), status: 400)
        }
        guard let method = object["method"]?.stringValue else {
            // A response from the client; this server never sends requests, so just accept it.
            return HTTPResponse(status: 202)
        }
        guard let id = object["id"], id != .null else {
            // Notifications (initialized, cancelled, …) need no reply.
            return HTTPResponse(status: 202)
        }
        let params = object["params"]

        switch method {
        case "initialize":
            return .json(Self.result(id: id, initializeResult(params)))
        case "ping":
            return .json(Self.result(id: id, [:]))
        case "tools/list":
            return .json(Self.result(id: id, ["tools": .array(tools.definitions)]))
        case "tools/call":
            guard let name = params?["name"]?.stringValue else {
                return .json(Self.error(id: id, code: -32602, message: "tools/call requires a tool name"))
            }
            do {
                let outcome = try tools.call(name, arguments: params?["arguments"])
                return .json(Self.result(id: id, Self.toolResult(outcome)))
            } catch {
                return .json(Self.error(id: id, code: -32602, message: "Unknown tool: \(error.name)"))
            }
        default:
            return .json(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "littlelog", "title": "littlelog", "version": .string(appVersion)],
            "instructions": .string(instructions()),
        ]
    }

    private func instructions() -> String {
        library.refreshDay()
        let today = library.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        return """
        littlelog is the user's personal notes and daily task list on their Mac. \
        Today is \(today) (\(library.dayKey)) in the user's time zone. \
        Each task belongs to one local day; dates accept today, tomorrow, yesterday or YYYY-MM-DD. \
        Call list_tasks before changing tasks so you use real ids. \
        Keep task text short and in the user's own words. \
        Prefer set_task_completed over delete_task. Notes are read-only.
        """
    }

    private static func toolResult(_ outcome: AssistantTools.Outcome) -> JSONValue {
        let text: String
        do {
            text = String(decoding: try outcome.structured.encoded(), as: UTF8.self)
        } catch {
            text = "littlelog couldn't encode the result."
        }
        return [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": outcome.structured,
            "isError": .bool(outcome.isError),
        ]
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    // MARK: Request checks

    nonisolated static func bearerToken(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        let token = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// This Mac's public address, e.g. `https://relay.example/d/<device>`, from the relay's
    /// forwarding headers. Requests without them didn't come through the relay and are refused.
    nonisolated static func baseURL(for request: HTTPRequest) -> String? {
        guard request.header("x-forwarded-proto") == "https",
              let host = request.header("host")?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              !host.contains("/")
        else { return nil }
        let prefix = request.header("x-forwarded-prefix") ?? ""
        guard prefix.isEmpty || prefix.wholeMatch(of: /\/d\/[0-9a-f]{32}/) != nil else { return nil }
        return "https://\(host)\(prefix)"
    }
}
