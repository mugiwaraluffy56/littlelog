import Foundation

/// The OAuth endpoints the MCP authorization spec asks for, so ChatGPT can show a normal
/// "Connect" button: protected-resource and authorization-server metadata (RFC 9728 / RFC 8414),
/// dynamic client registration (RFC 7591), and the authorization-code + PKCE flow.
final class OAuthEndpoints {
    static let scope = "littlelog"

    let store: OAuthStore
    private let approve: (_ appName: String, _ returnHost: String) async -> Bool

    init(store: OAuthStore, approve: @escaping (_ appName: String, _ returnHost: String) async -> Bool) {
        self.store = store
        self.approve = approve
    }

    /// RFC 9728: where ChatGPT learns which authorization server protects `/mcp`.
    func protectedResourceMetadata(baseURL: String) -> HTTPResponse {
        .json([
            "resource": .string(baseURL + MCPServer.endpointPath),
            "authorization_servers": [.string(baseURL)],
            "bearer_methods_supported": ["header"],
            "scopes_supported": [.string(Self.scope)],
            "resource_name": "littlelog",
        ])
    }

    /// RFC 8414: the sign-in endpoints and what they support.
    func authorizationServerMetadata(baseURL: String) -> HTTPResponse {
        .json([
            "issuer": .string(baseURL),
            "authorization_endpoint": .string(baseURL + "/oauth/authorize"),
            "token_endpoint": .string(baseURL + "/oauth/token"),
            "registration_endpoint": .string(baseURL + "/oauth/register"),
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": [.string(Self.scope)],
        ])
    }

    // MARK: Registration

    func register(_ request: HTTPRequest) -> HTTPResponse {
        guard let metadata = try? JSONValue.decode(request.body), metadata.objectValue != nil else {
            return Self.oauthError("invalid_client_metadata", "Body must be a JSON object", status: 400)
        }
        guard let redirectValues = metadata["redirect_uris"]?.arrayValue,
              redirectValues.allSatisfy({ $0.stringValue != nil })
        else {
            return Self.oauthError("invalid_client_metadata", "redirect_uris must be an array of strings", status: 400)
        }
        let redirects = redirectValues.compactMap(\.stringValue)
        if let method = metadata["token_endpoint_auth_method"]?.stringValue, method != "none" {
            return Self.oauthError("invalid_client_metadata", "Only public clients (token_endpoint_auth_method none) are supported", status: 400)
        }
        do {
            let client = try store.register(name: metadata["client_name"]?.stringValue ?? "", redirectURIs: redirects)
            return .json([
                "client_id": .string(client.id),
                "client_name": .string(client.name),
                "redirect_uris": .array(client.redirectURIs.map(JSONValue.string)),
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
                "client_id_issued_at": .int(Int(client.createdAt.timeIntervalSince1970)),
            ], status: 201)
        } catch OAuthStore.Failure.invalidRequest(let message) {
            return Self.oauthError("invalid_redirect_uri", message, status: 400)
        } catch {
            return Self.oauthError("server_error", "Couldn't save the registration: \(error.localizedDescription)", status: 500)
        }
    }

    // MARK: Authorization

    func authorize(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.query
        // Until the client and redirect URI check out, errors are shown here, never redirected.
        guard let clientID = query["client_id"], let client = store.client(id: clientID) else {
            return .page(title: "Unknown app", message: "This sign-in link isn't from an app registered with littlelog.", status: 400)
        }
        guard let redirectURI = query["redirect_uri"], client.redirectURIs.contains(redirectURI),
              let returnHost = URLComponents(string: redirectURI)?.host
        else {
            return .page(title: "Invalid sign-in link", message: "The return address doesn't match the app's registration.", status: 400)
        }
        let state = query["state"]
        guard query["response_type"] == "code" else {
            return .redirect(to: Self.redirect(redirectURI, ["error": "unsupported_response_type", "state": state]))
        }
        guard let challenge = query["code_challenge"], !challenge.isEmpty, query["code_challenge_method"] == "S256" else {
            return .redirect(to: Self.redirect(redirectURI, [
                "error": "invalid_request", "error_description": "PKCE with S256 is required", "state": state,
            ]))
        }

        guard await approve(client.name, returnHost) else {
            return .redirect(to: Self.redirect(redirectURI, [
                "error": "access_denied", "error_description": "Not allowed on the Mac", "state": state,
            ]))
        }
        do {
            let code = try store.issueCode(clientID: client.id, redirectURI: redirectURI, codeChallenge: challenge)
            return .redirect(to: Self.redirect(redirectURI, ["code": code, "state": state]))
        } catch {
            return .redirect(to: Self.redirect(redirectURI, ["error": "server_error", "state": state]))
        }
    }

    // MARK: Tokens

    func token(_ request: HTTPRequest) -> HTTPResponse {
        let form = FormEncoding.decode(String(decoding: request.body, as: UTF8.self))
        guard let clientID = form["client_id"], store.client(id: clientID) != nil else {
            return Self.oauthError("invalid_client", "Unknown client_id", status: 401)
        }
        do {
            let pair: OAuthStore.TokenPair
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"], let redirectURI = form["redirect_uri"], let verifier = form["code_verifier"] else {
                    return Self.oauthError("invalid_request", "code, redirect_uri and code_verifier are required", status: 400)
                }
                pair = try store.exchange(code: code, clientID: clientID, redirectURI: redirectURI, codeVerifier: verifier)
            case "refresh_token":
                guard let refresh = form["refresh_token"] else {
                    return Self.oauthError("invalid_request", "refresh_token is required", status: 400)
                }
                pair = try store.refresh(refresh, clientID: clientID)
            default:
                return Self.oauthError("unsupported_grant_type", "Use authorization_code or refresh_token", status: 400)
            }
            return .json([
                "access_token": .string(pair.accessToken),
                "token_type": "Bearer",
                "expires_in": .int(pair.expiresIn),
                "refresh_token": .string(pair.refreshToken),
                "scope": .string(Self.scope),
            ])
        } catch OAuthStore.Failure.invalidGrant(let message) {
            return Self.oauthError("invalid_grant", message, status: 400)
        } catch {
            return Self.oauthError("server_error", error.localizedDescription, status: 500)
        }
    }

    // MARK: Helpers

    private static func oauthError(_ code: String, _ description: String, status: Int) -> HTTPResponse {
        .json(["error": .string(code), "error_description": .string(description)], status: status)
    }

    private static func redirect(_ uri: String, _ parameters: [String: String?]) -> String {
        guard var components = URLComponents(string: uri) else { return uri }
        var items = components.queryItems ?? []
        for (name, value) in parameters.sorted(by: { $0.key < $1.key }) {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        components.queryItems = items
        return components.string ?? uri
    }
}
