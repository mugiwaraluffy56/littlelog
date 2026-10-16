import Foundation

/// Edits `~/.codex/config.toml` text: replaces littlelog's own tables and leaves everything else,
/// including comments and other MCP servers, untouched.
nonisolated enum CodexConfig {
    static let tableName = "mcp_servers.littlelog"

    static func merging(_ existing: String, block: String) -> String {
        let kept = removingLittlelogTables(from: existing)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return kept.isEmpty ? block + "\n" : kept + "\n\n" + block + "\n"
    }

    /// Drops `[mcp_servers.littlelog]` and its sub-tables, each up to the next table header.
    static func removingLittlelogTables(from text: String) -> String {
        var output: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let header = tableHeader(line) {
                skipping = header == tableName || header.hasPrefix(tableName + ".")
            }
            if !skipping { output.append(line) }
        }
        return output.joined(separator: "\n")
    }

    /// The name inside `[name]` or `[[name]]`, with surrounding quotes and spaces removed.
    private static func tableHeader(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return inner
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .joined(separator: ".")
    }
}
