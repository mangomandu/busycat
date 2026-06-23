// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BusyCat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BusyCat",
            path: "Sources/BusyCat"
        )
    ]
)
