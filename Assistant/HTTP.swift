import Foundation

nonisolated struct HTTPRequest: Sendable {
    let method: String
    /// The request target without its query string, e.g. `/mcp`.
    let path: String
    /// Percent-decoded query parameters; the first occurrence of a name wins.
    var query: [String: String] = [:]
    let version: String
    /// Header names are lowercased; repeated headers are joined with ", ".
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var keepsAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
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
            return HTTPResponse(status: 500, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("encoding failed".utf8))
        }
    }

    static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: ["Location": location])
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

    static func text(_ message: String, status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        var merged = headers
        merged["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: merged, body: Data(message.utf8))
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = keepAlive ? "keep-alive" : "close"
        allHeaders["Cache-Control"] = "no-store"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// A strict, minimal HTTP/1.1 request parser: one request at a time, `Content-Length` bodies only.
nonisolated enum HTTPParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum Result: Sendable {
        case incomplete
        case request(HTTPRequest, remainder: Data)
        case invalid(HTTPResponse)
    }

    static func parse(_ buffer: Data) -> Result {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes
                ? .invalid(.text("Headers too large", status: 431))
                : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            return .invalid(.text("Headers too large", status: 431))
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(.text("Headers must be UTF-8", status: 400))
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(.text("Malformed request line", status: 400))
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(.text("Malformed header", status: 400))
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(.text("Malformed header", status: 400)) }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(.text("Chunked request bodies are not supported", status: 501))
        }
        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else {
                return .invalid(.text("Invalid Content-Length", status: 400))
            }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else {
            return .invalid(.text("Request body too large", status: 413))
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let bodyEnd = bodyStart + length

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? target
        let query = parts.count > 1 ? formDecode(String(parts[1])) : [:]
        let request = HTTPRequest(
            method: String(requestLine[0]),
            path: path,
            query: query,
            version: String(requestLine[2]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
        return .request(request, remainder: Data(buffer[bodyEnd...]))
    }

    /// Decodes `application/x-www-form-urlencoded` text (also used for query strings).
    static func formDecode(_ text: String) -> [String: String] {
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
