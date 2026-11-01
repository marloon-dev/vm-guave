// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BootGuave",
    platforms: [.macOS(.v14)],
    targets: [
        // Protocolo compartilhado entre o app e o bgctl (socket Unix + JSON).
        .target(
            name: "ControlProtocol",
            path: "Sources/ControlProtocol"
        ),
        .executableTarget(
            name: "BootGuave",
            dependencies: ["ControlProtocol"],
            path: "Sources/BootGuave",
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("vmnet")]
        ),
        .executableTarget(
            name: "bgctl",
            dependencies: ["ControlProtocol"],
            path: "Sources/bgctl"
        ),
    ],
    swiftLanguageModes: [.v5]
)
