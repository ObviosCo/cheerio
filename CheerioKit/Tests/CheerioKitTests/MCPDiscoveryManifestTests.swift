import Foundation
import Testing

@testable import CheerioKit

/// The discovery manifest (issue #135): what Cheerio writes so a local agent can find
/// the bundled MCP server without a human pasting config.
///
/// Everything runs against a temporary directory standing in for
/// `~/Library/Application Support` — same reason the store-resolution tests in
/// `MeetingMCPTests` never touch the real one: a developer's Mac may hold a real
/// manifest there that these tests must neither read nor clobber.
@Suite struct MCPDiscoveryManifestTests {
    /// A scratch "Application Support" plus a fake app bundle whose helper actually
    /// exists and is executable, since `refresh` refuses to advertise anything less.
    private struct Fixture {
        let root: URL
        let appBundle: URL

        init() throws {
            root = URL(filePath: NSTemporaryDirectory())
                .appending(path: "cheerio-manifest-\(UUID().uuidString)")
            appBundle = root.appending(path: "Somewhere/Cheerio.app")
            try Self.installHelper(in: appBundle)
        }

        static func installHelper(in bundle: URL) throws {
            let helper = MCPClientSetup.helperURL(appBundle: bundle)
            try FileManager.default.createDirectory(
                at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: helper)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        }

        var applicationSupport: URL { root.appending(path: "Application Support") }
        var manifestURL: URL { MCPDiscoveryManifest.manifestURL(applicationSupport: applicationSupport) }

        func refresh(version: String? = "1.2.3", now: Date = .now) throws -> MCPDiscoveryManifest.Outcome {
            try MCPDiscoveryManifest.refresh(
                helperURL: MCPClientSetup.helperURL(appBundle: appBundle),
                manifestURL: manifestURL,
                version: version,
                now: now
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func theManifestLivesAtTheDocumentedPath() {
        // The README states this path as a literal string an agent can follow; if it
        // moves, the docs and this expectation move together.
        let url = MCPDiscoveryManifest.manifestURL(
            applicationSupport: URL(filePath: "/Users/x/Library/Application Support"))
        #expect(url.path(percentEncoded: false) == "/Users/x/Library/Application Support/Cheerio/mcp-server.json")
    }

    @Test func aRefreshWritesEverythingAnAgentNeedsToConnect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let outcome = try fixture.refresh(version: "2.0.1", now: stamp)
        #expect(outcome == .written(fixture.manifestURL))

        let data = try Data(contentsOf: fixture.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(MCPDiscoveryManifest.Contents.self, from: data)

        #expect(contents.name == MCPClientSetup.serverName)
        #expect(contents.version == "2.0.1")
        #expect(contents.transport.type == "stdio")
        #expect(contents.command == MCPClientSetup.helperURL(appBundle: fixture.appBundle).path(percentEncoded: false))
        // The advertised command must be launchable as-is — that's the whole promise.
        #expect(FileManager.default.isExecutableFile(atPath: contents.command))
        #expect(abs(contents.updatedAt.timeIntervalSince(stamp)) < 1)

        // Plain-JSON view too, not just round-tripping through our own Codable: an
        // agent in any language sees these exact keys.
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(parsed.keys) == ["name", "description", "version", "command", "transport", "updatedAt"])
        // `.withoutEscapingSlashes` holds: the path reads like a path, not \/-soup.
        #expect(String(decoding: data, as: UTF8.self).contains(contents.command))
    }

    @Test func relaunchingFromANewLocationRewritesTheCommand() throws {
        // The move-to-Applications flow and plain drag-installs both change where the
        // helper is; the manifest must follow the app, not remember where it was.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.refresh()

        let movedBundle = fixture.root.appending(path: "Applications/Cheerio.app")
        try FileManager.default.createDirectory(
            at: movedBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.appBundle, to: movedBundle)

        let outcome = try MCPDiscoveryManifest.refresh(
            helperURL: MCPClientSetup.helperURL(appBundle: movedBundle),
            manifestURL: fixture.manifestURL,
            version: "1.2.3",
            now: .now
        )
        #expect(outcome == .written(fixture.manifestURL))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(
            MCPDiscoveryManifest.Contents.self, from: Data(contentsOf: fixture.manifestURL))
        #expect(contents.command == MCPClientSetup.helperURL(appBundle: movedBundle).path(percentEncoded: false))
    }

    @Test func aMissingHelperLeavesTheExistingManifestAlone() throws {
        // A copy of the app without its helper has nothing true to advertise — and it
        // must not destroy an advertisement some intact copy already wrote.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.refresh()
        let before = try Data(contentsOf: fixture.manifestURL)

        let gutted = fixture.root.appending(path: "Gutted/Cheerio.app")
        try FileManager.default.createDirectory(at: gutted, withIntermediateDirectories: true)
        let outcome = try MCPDiscoveryManifest.refresh(
            helperURL: MCPClientSetup.helperURL(appBundle: gutted),
            manifestURL: fixture.manifestURL,
            version: nil,
            now: .now
        )
        #expect(outcome == .helperMissing)
        #expect(try Data(contentsOf: fixture.manifestURL) == before)
    }

    @Test func theFirstRefreshCreatesTheDirectoryItself() throws {
        // Nothing else makes `Application Support/Cheerio` exist — the app's own data
        // container is named by bundle identifier, not this.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: fixture.applicationSupport.path))

        let outcome = try fixture.refresh()
        #expect(outcome == .written(fixture.manifestURL))
        #expect(FileManager.default.fileExists(atPath: fixture.manifestURL.path(percentEncoded: false)))
    }

    @Test func aBuildWithoutAVersionStillAdvertises() throws {
        // Version is metadata; discovery must not fail because a dev build's
        // Info.plist lacks a marketing version.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.refresh(version: nil)

        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any])
        #expect(parsed["version"] == nil)
        #expect(parsed["command"] != nil)
    }
}
