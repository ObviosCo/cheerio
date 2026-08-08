import CheerioKit
import Foundation

// `cheerio-mcp` — the MCP server that ships inside Cheerio.app (issue #28), so a local
// agent can ask what was said in a meeting without Cheerio having initiated anything.
//
// This file is the whole executable and it is deliberately thin. Every answer comes
// from `CheerioKit`: `MeetingStore` opens the app's store read-only, `MeetingQueryService`
// runs the queries, and `CheerioMCPResponder` maps one JSON-RPC message to one reply.
// What's left here is argument handling, working out which store and which version, and
// the loop — the parts that need a process to exercise, which the smoke test in the PR
// does and a unit test can't.
//
// stdio only. There is no socket, no listener, and no networking code anywhere in this
// target or in what it links: an agent reaches Cheerio because the client launched this
// process and holds its pipes, and nothing off this machine can reach it at all.

/// The version to report over `initialize`.
///
/// Read out of the enclosing app's `Info.plist` — the helper lives at
/// `Cheerio.app/Contents/Helpers/cheerio-mcp`, so the plist is two directories up. That
/// way the version an agent sees is the app's own rather than a second number to keep
/// in step, and running the binary from a build directory just reports "dev".
func hostAppVersion() -> String {
    let plist = URL(filePath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()  // Helpers
        .deletingLastPathComponent()  // Contents
        .appending(path: "Info.plist")
    // `FileManager.contents(atPath:)` rather than `Data(contentsOf:)`: the latter
    // accepts any URL scheme, so referencing it links CFNetwork into this binary —
    // which is exactly the kind of thing this target is supposed to be able to prove it
    // doesn't do. Verified with `otool -L`, which lists no networking framework at all.
    guard let data = FileManager.default.contents(atPath: plist.path(percentEncoded: false)),
        let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let version = parsed["CFBundleShortVersionString"] as? String
    else { return "dev" }
    return version
}

let usage = """
    cheerio-mcp — read Cheerio's meeting history over the Model Context Protocol.

    Speaks MCP over stdio: it is launched by an MCP client, not run by hand. Every tool
    is read-only, and it never writes to the store or opens a network connection.

    Usage: cheerio-mcp [--version | --help]

    Environment:
      \(MeetingStore.storePathEnvironmentKey)   Read this store file instead of the app's own.
                            Point it at a copy to try things out safely.

    Add it to a client with:
      claude mcp add cheerio -- "$(pwd)/cheerio-mcp"
    or see Cheerio's Settings, which shows the installed path and a ready-made config.
    """

switch CommandLine.arguments.dropFirst().first {
case "--version", "-v":
    print(hostAppVersion())
    exit(0)
case "--help", "-h":
    print(usage)
    exit(0)
case .some(let argument):
    // Not silently ignored: a typo in a client's config is otherwise a server that
    // starts fine and behaves subtly differently from what was intended.
    StandardIO.note("unrecognized argument “\(argument)”. Try --help.")
    exit(64)  // EX_USAGE
case .none:
    break
}

let storeURL: URL
do {
    storeURL = try MeetingStore.resolveStoreURL()
} catch {
    // Application Support itself is unreachable, which is not a state to serve
    // requests in. Note that a *missing store* is not this case — that one is reported
    // per tool call, so a client that started before Cheerio ever ran recovers on its
    // own once it has.
    StandardIO.note("couldn't work out where Cheerio keeps its data: \(error)")
    exit(70)  // EX_SOFTWARE
}
StandardIO.note("serving \(storeURL.path(percentEncoded: false)) read-only")

let responder = CheerioMCPResponder(
    storeURL: storeURL,
    info: CheerioMCPResponder.Info(version: hostAppVersion())
)

for line in StandardIO.lines() {
    if let reply = await responder.respond(to: line) {
        StandardIO.writeLine(reply)
    }
}
