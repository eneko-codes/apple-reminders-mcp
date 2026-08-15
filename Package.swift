// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-reminders-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        .target(
            name: "RemindersMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "apple-reminders-mcp",
            dependencies: ["RemindersMCPCore"],
            // TCC identifies this binary by its own embedded Info.plist. Claude Desktop
            // spawns MCP servers through Contents/Helpers/disclaimer, which calls
            // responsibility_spawnattrs_setdisclaim, so the process is its own TCC
            // subject and cannot borrow the host app's usage descriptions. Without the
            // embedded plist macOS denies reminder access without ever prompting.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "RemindersMCPCoreTests", dependencies: ["RemindersMCPCore"]),
    ]
)
