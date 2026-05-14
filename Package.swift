// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeStatusBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudeStatusBar"),
        .target(name: "ClaudeStatusBarHookCore"),
        .executableTarget(
            name: "ClaudeStatusBarHook",
            dependencies: ["ClaudeStatusBarHookCore"]
        ),
        .testTarget(name: "ClaudeStatusBarTests", dependencies: ["ClaudeStatusBar"]),
        .testTarget(
            name: "ClaudeStatusBarHookTests",
            dependencies: ["ClaudeStatusBarHookCore"]
        ),
    ]
)
