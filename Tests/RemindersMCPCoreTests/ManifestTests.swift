import Foundation
import Testing

@testable import RemindersMCPCore

/// Checks the packaging metadata against the code it describes.
///
/// None of this is reachable from the server at runtime, which is exactly why it drifts:
/// a tool added to `ToolCatalog` but not to the manifest simply has no permission switch
/// in Claude Desktop, and nothing anywhere reports that.
@Suite("Extension manifest")
struct ManifestTests {

    /// The repository root, found from this file rather than the working directory, which
    /// `swift test` does not promise anything about.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RemindersMCPCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appending(path: "extension/manifest.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Claude Desktop lists and toggles tools from the manifest before the server has ever
    /// run, so this array is what creates the switches.
    @Test("The manifest declares exactly the tools the catalogue serves")
    func manifestMatchesCatalogue() throws {
        let declared = try #require(try manifest()["tools"] as? [[String: Any]])
        let names = Set(declared.compactMap { $0["name"] as? String })
        #expect(names == Set(ToolCatalog.all().map(\.name)))
        for tool in declared {
            let description = tool["description"] as? String
            #expect(description?.isEmpty == false, "\(tool["name"] ?? "?") has no description")
        }
    }

    /// Three files carry the version and nothing reconciles them. A bundle whose manifest
    /// disagrees with the binary is the kind of thing only noticed while debugging
    /// something else.
    @Test("Manifest, Info.plist and the server agree on the version")
    func versionsAgree() throws {
        let manifest = try manifest()
        let plist = try infoPlist()
        #expect(manifest["version"] as? String == RemindersMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == RemindersMCPServer.version)
    }

    /// The identifier the designated requirement quotes. `pack.sh` pins the same string;
    /// if they ever disagree, TCC sees two different subjects.
    @Test("The bundle identifier matches the one pack.sh signs with")
    func bundleIdentifierIsPinned() throws {
        let plist = try infoPlist()
        #expect(plist["CFBundleIdentifier"] as? String == "codes.eneko.apple-reminders-mcp")
        #expect(plist["CFBundleName"] as? String == RemindersMCPServer.name)

        let script = try String(
            contentsOf: Self.root.appending(path: "scripts/pack.sh"), encoding: .utf8)
        #expect(script.contains("codes.eneko.$NAME"))
        #expect(script.contains("NAME=\"\(RemindersMCPServer.name)\""))
    }

    /// The usage description key is what macOS looks for. A wrong one means the permission
    /// is denied with no prompt at all — the single most confusing way this can fail.
    @Test("The Info.plist carries the reminders usage description")
    func usageDescriptionIsPresent() throws {
        let description =
            try infoPlist()["NSRemindersFullAccessUsageDescription"] as? String
        #expect(description?.isEmpty == false)
    }

    /// Plug and play: nothing here is configurable beyond Claude Desktop's own per-tool
    /// switches, so there is no `user_config` and nothing to substitute into `args`.
    @Test("There is no user-configurable setting left")
    func noUserConfigRemains() throws {
        let manifest = try manifest()
        #expect(manifest["user_config"] == nil)
        let server = try #require(manifest["server"] as? [String: Any])
        let config = try #require(server["mcp_config"] as? [String: Any])
        let arguments = try #require(config["args"] as? [String])
        #expect(arguments.isEmpty)
    }
}
