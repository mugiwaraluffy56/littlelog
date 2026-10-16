import Foundation

/// A request forwarded by the relay.
nonisolated struct HTTPRequest: Sendable {
    let method: String
    /// The path within this Mac's address, e.g. `/mcp`.
    let path: String
    /// Percent-decoded query parameters; the first occurrence of a name wins.
    var query: [String: String] = [:]
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        do {
            return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: try value.encoded())
        } catch {
            return .text("encoding failed", status: 500)
        }
    }

    static func text(_ message: String, status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        var merged = headers
        merged["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: merged, body: Data(message.utf8))
    }

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: ["Location": location, "Cache-Control": "no-store"])
    }

    /// A small self-contained page for people who land on a sign-in URL in a browser.
    static func page(title: String, message: String, status: Int) -> HTTPResponse {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.5 -apple-system, system-ui, sans-serif; display: grid; place-items: center;
               min-height: 100vh; margin: 0; padding: 0 16px; background: Canvas; color: CanvasText; }
        main { max-width: 420px; text-align: center; }
        h1 { font-size: 20px; font-weight: 600; margin: 0 0 8px; }
        p { margin: 0; opacity: .7; }
        </style></head>
        <body><main><h1>\(escape(title))</h1><p>\(escape(message))</p></main></body></html>
        """
        return HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }
}

nonisolated enum FormEncoding {
    /// Decodes `application/x-www-form-urlencoded` text (also used for query strings).
    static func decode(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String {
                String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(value)
            }
            let name = decode(pieces[0])
            guard !name.isEmpty, result[name] == nil else { continue }
            result[name] = pieces.count > 1 ? decode(pieces[1]) : ""
        }
        return result
    }
}
