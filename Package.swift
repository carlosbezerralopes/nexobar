// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NexoBar", platforms: [.macOS(.v14)], products: [.executable(name: "NexoBar", targets: ["NexoBar"])], targets: [.executableTarget(name: "NexoBar", swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "NexoBarTests", dependencies: ["NexoBar"], swiftSettings: [.swiftLanguageMode(.v5)])])
