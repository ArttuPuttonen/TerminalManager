// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TerminalManager",
            path: "Sources/TerminalManager"
        ),
    ]
)
