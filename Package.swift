// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ios-simulator-mcp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ios-simulator-mcp", targets: ["IOSSimulatorMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "IOSSimulatorMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/IOSSimulatorMCP"
        ),
    ]
)
