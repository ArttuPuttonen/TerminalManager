// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalManager",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.99.0")),
    ],
    targets: [
        .executableTarget(
            name: "TerminalManager",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/TerminalManager"
        ),
    ]
)
