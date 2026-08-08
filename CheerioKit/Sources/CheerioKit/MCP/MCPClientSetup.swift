import Foundation

/// Where the bundled MCP helper is, and what to paste into a client to reach it.
///
/// Cheerio does not write anyone else's config file. Editing `claude_desktop_config.json`
/// or `~/.codex/config.toml` from here would mean a meeting recorder silently rewriting
/// the configuration of the agent that reads it — the wrong direction of trust entirely,
/// and unrecoverable if the format changes under us. So this generates the text and
/// Settings offers it to copy; the user pastes it, or doesn't.
public enum MCPClientSetup {
    /// Name to register the server under. Short, because a client prefixes tool names
    /// with it and the agent reads the result.
    public static let serverName = "cheerio"

    /// Subdirectory of the app bundle holding the helper. See `project.yml` for the copy
    /// phase that puts it there.
    public static let helperSubpath = "Contents/Helpers/cheerio-mcp"

    /// The helper inside a given app bundle.
    ///
    /// - Parameter appBundle: normally `Bundle.main.bundleURL`. Passed in rather than
    ///   read here so this stays testable and so the string a user copies is the path to
    ///   *this* copy of Cheerio — whether that's `/Applications` or a build directory —
    ///   rather than a guess about where it ought to be installed.
    public static func helperURL(appBundle: URL) -> URL {
        appBundle.appending(path: helperSubpath)
    }

    /// Config for Claude Desktop's `claude_desktop_config.json`, and for anything else
    /// that takes the same `mcpServers` object.
    public static func desktopJSON(helperPath: String) -> String {
        // Hand-built rather than encoded, because what's wanted here is *readable*
        // indented JSON a person can see the shape of, with the key order they'd expect
        // — and `JSONEncoder` sorts keys and can't be told not to escape a path the way
        // a human would read it. Paths go through `escaped` so a folder with a quote or a
        // backslash in it can't produce invalid JSON.
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "\(escaped(helperPath))"
            }
          }
        }
        """
    }

    /// One-liner for the Claude Code CLI.
    public static func claudeCodeCommand(helperPath: String) -> String {
        "claude mcp add \(serverName) -- \(shellQuoted(helperPath))"
    }

    /// Config for Codex's `~/.codex/config.toml`.
    public static func codexTOML(helperPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(escaped(helperPath))"
        """
    }

    /// Escapes a path for embedding in a JSON or TOML basic string: backslash, quote,
    /// and the whole C0 control range. macOS path components can legally contain tabs
    /// and newlines, and both formats reject raw control characters — emitted
    /// literally, one odd folder name produces a config file the client can't parse.
    /// `\uXXXX` is valid in both formats, so one escaper serves the two snippets.
    static func escaped(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case let c where c.value < 0x20:
                out += String(format: "\\u%04X", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Single-quoted for a shell, since app bundles live in paths with spaces in them
    /// often enough to matter.
    static func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
