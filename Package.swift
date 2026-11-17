// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PromptDock",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "PromptDockCore", dependencies: ["Yams"]),
        .executableTarget(name: "PromptDock", dependencies: ["PromptDockCore"]),
        .testTarget(name: "PromptDockCoreTests", dependencies: ["PromptDockCore"]),
    ]
)
