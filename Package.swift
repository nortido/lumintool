// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LuminTool",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LuminTool", targets: ["LuminTool"])],
    targets: [
        .target(name: "LuminToolCore"),
        .executableTarget(name: "LuminTool", dependencies: ["LuminToolCore"]),
        .testTarget(name: "LuminToolCoreTests", dependencies: ["LuminToolCore"])
    ],
    swiftLanguageModes: [.v5]
)
