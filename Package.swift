// swift-tools-version: 6.0
import PackageDescription
// Widget extensions link only app-extension-safe APIs and enter through _NSExtensionMain, as Xcode does;
// with the plain Swift main, ExtensionFoundation traps because the extension type is never set.
let extensionSafe: [SwiftSetting] = [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])]
let package = Package(
    name: "NexoBar", platforms: [.macOS(.v14)],
    products: [.executable(name: "NexoBar", targets: ["NexoBar"]), .executable(name: "NexoBarWorkersWidget", targets: ["NexoBarWorkersWidget"])],
    targets: [
        .target(name: "WorkersTelemetry", swiftSettings: extensionSafe),
        .executableTarget(name: "NexoBar", dependencies: ["WorkersTelemetry"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "NexoBarWorkersWidget", dependencies: ["WorkersTelemetry"], swiftSettings: extensionSafe,
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "NexoBarTests", dependencies: ["NexoBar"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WorkersTelemetryTests", dependencies: ["WorkersTelemetry"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
