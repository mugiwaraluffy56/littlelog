import CryptoKit
import Foundation
import OSLog

/// The authorization server state behind the MCP OAuth flow (OAuth 2.1, dynamic client
/// registration, PKCE S256). Registered clients and token grants persist in the sandbox container;
/// tokens are stored only as SHA-256 hashes. Authorization codes live in memory for five minutes.
final class OAuthStore {
    static let accessTokenLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let refreshTokenLifetime: TimeInterval = 365 * 24 * 60 * 60
    static let codeLifetime: TimeInterval = 5 * 60

    struct Client: Codable, Equatable {
        let id: String
        let name: String
        let redirectURIs: [String]
        let createdAt: Date
    }

    struct Grant: Codable {
        let clientID: String
        let kind: Kind
        let expiresAt: Date

        enum Kind: String, Codable {
            case access
            case refresh
        }
    }

    struct TokenPair {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    private struct PendingCode {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let expiresAt: Date
    }

    private struct Snapshot: Codable {
        var clients: [String: Client] = [:]
        var grants: [String: Grant] = [:]
    }

    enum Failure: Error, Equatable {
        case invalidGrant(String)
        case invalidRequest(String)
    }

    private let url: URL?
    private let now: () -> Date
    private var snapshot = Snapshot()
    private var codes: [String: PendingCode] = [:]

    /// `url == nil` keeps everything in memory (tests).
    init(url: URL?, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                snapshot = try decoder.decode(Snapshot.self, from: data)
            } catch {
                Logger.app.error("ignoring unreadable OAuth store: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "littlelog", directoryHint: .isDirectory)
            .appending(path: "oauth.json", directoryHint: .notDirectory)
    }

    // MARK: Clients

    func register(name: String, redirectURIs: [String]) throws -> Client {
        guard !redirectURIs.isEmpty, redirectURIs.allSatisfy(Self.isAcceptableRedirect) else {
            throw Failure.invalidRequest("redirect_uris must be https URLs (or http on localhost)")
        }
        let client = Client(
            id: try Self.randomToken(),
            name: name.isEmpty ? "Unnamed app" : String(name.prefix(80)),
            redirectURIs: redirectURIs,
            createdAt: now()
        )
        snapshot.clients[client.id] = client
        try persist()
        return client
    }

    func client(id: String) -> Client? {
        snapshot.clients[id]
    }

    /// Apps that currently hold a usable token, for the menu.
    var connectedClients: [Client] {
        let current = now()
        let ids = Set(snapshot.grants.values.filter { $0.expiresAt > current }.map(\.clientID))
        return ids.compactMap { snapshot.clients[$0] }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Codes and tokens

    func issueCode(clientID: String, redirectURI: String, codeChallenge: String) throws -> String {
        let code = try Self.randomToken()
        codes[code] = PendingCode(
            clientID: clientID,
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            expiresAt: now().addingTimeInterval(Self.codeLifetime)
        )
        return code
    }

    func exchange(code: String, clientID: String, redirectURI: String, codeVerifier: String) throws -> TokenPair {
        // Codes are single use, even when the exchange fails.
        guard let pending = codes.removeValue(forKey: code) else {
            throw Failure.invalidGrant("unknown or already used code")
        }
        guard pending.expiresAt > now() else { throw Failure.invalidGrant("code expired") }
        guard pending.clientID == clientID else { throw Failure.invalidGrant("code was issued to another client") }
        guard pending.redirectURI == redirectURI else { throw Failure.invalidGrant("redirect_uri mismatch") }
        guard Self.s256(codeVerifier) == pending.codeChallenge else {
            throw Failure.invalidGrant("PKCE verification failed")
        }
        return try issueTokens(clientID: clientID)
    }

    /// Refresh tokens rotate: the presented one stops working.
    func refresh(_ refreshToken: String, clientID: String) throws -> TokenPair {
        let key = Self.hash(refreshToken)
        guard let grant = snapshot.grants[key], grant.kind == .refresh, grant.clientID == clientID else {
            throw Failure.invalidGrant("unknown refresh token")
        }
        snapshot.grants[key] = nil
        guard grant.expiresAt > now() else {
            try persist()
            throw Failure.invalidGrant("refresh token expired")
        }
        return try issueTokens(clientID: clientID)
    }

    func isValidAccessToken(_ token: String) -> Bool {
        guard let grant = snapshot.grants[Self.hash(token)], grant.kind == .access else { return false }
        return grant.expiresAt > now() && snapshot.clients[grant.clientID] != nil
    }

    /// Disconnects every app: all clients and tokens are forgotten.
    func revokeAll() throws {
        snapshot = Snapshot()
        codes.removeAll()
        try persist()
    }

    private func issueTokens(clientID: String) throws -> TokenPair {
        let access = try Self.randomToken()
        let refresh = try Self.randomToken()
        let current = now()
        snapshot.grants = snapshot.grants.filter { $0.value.expiresAt > current }
        snapshot.grants[Self.hash(access)] = Grant(
            clientID: clientID, kind: .access, expiresAt: current.addingTimeInterval(Self.accessTokenLifetime)
        )
        snapshot.grants[Self.hash(refresh)] = Grant(
            clientID: clientID, kind: .refresh, expiresAt: current.addingTimeInterval(Self.refreshTokenLifetime)
        )
        try persist()
        return TokenPair(accessToken: access, refreshToken: refresh, expiresIn: Int(Self.accessTokenLifetime))
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: Crypto helpers

    nonisolated static func s256(_ verifier: String) -> String {
        SecureRandom.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func hash(_ token: String) -> String {
        SecureRandom.base64URL(Data(SHA256.hash(data: Data(token.utf8))))
    }

    private static func randomToken() throws -> String {
        try SecureRandom.token()
    }

    nonisolated static func isAcceptableRedirect(_ uri: String) -> Bool {
        guard let components = URLComponents(string: uri), components.fragment == nil,
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }
}
