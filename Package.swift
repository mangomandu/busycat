// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RuncatGPU",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RuncatGPU",
            path: "Sources/RuncatGPU"
        )
    ]
)
