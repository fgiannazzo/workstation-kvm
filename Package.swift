// swift-tools-version: 6.0
import PackageDescription

// Targets land one tracer bullet at a time; see docs/DESIGN.md for the full layout and
// dependency direction. Nothing depends on an executable.
let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "switchboardctl", targets: ["switchboardctl"]),
        .library(name: "SwitchboardCore", targets: ["SwitchboardCore"]),
        .library(name: "DDCKit", targets: ["DDCKit"]),
        .library(name: "Devices", targets: ["Devices"]),
        .library(name: "TinyHTTP", targets: ["TinyHTTP"]),
        .library(name: "ESP32Kit", targets: ["ESP32Kit"]),
    ],
    targets: [
        // C: declarations of the private IOAVService entry points. The symbols are exported by IOKit.
        .target(
            name: "IOAVServiceShim",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Shared value types and protocols. No dependencies, no I/O.
        .target(name: "SwitchboardCore"),
        // Packet encoders/decoders, DDCTransport, VideoCableDDC, FakeDDC, display enumeration.
        .target(
            name: "DDCKit",
            dependencies: ["IOAVServiceShim", "SwitchboardCore"]
        ),
        // LGDualUp: reads today; the whitelist and verify-after-write flow arrive in tracer bullet 2.
        .target(
            name: "Devices",
            dependencies: ["DDCKit", "SwitchboardCore"]
        ),
        .executableTarget(
            name: "switchboardctl",
            dependencies: ["Devices", "DDCKit", "SwitchboardCore"]
        ),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"]),
        .testTarget(name: "DDCKitTests", dependencies: ["DDCKit"]),
        .testTarget(name: "DevicesTests", dependencies: ["Devices", "DDCKit", "SwitchboardCore"]),
        // Networking (tracer bullet 6)
        .target(name: "TinyHTTP"),
        .target(name: "ESP32Kit", dependencies: ["TinyHTTP", "SwitchboardCore"]),
        .testTarget(name: "TinyHTTPTests", dependencies: ["TinyHTTP"]),
        .testTarget(name: "ESP32KitTests", dependencies: ["ESP32Kit", "TinyHTTP", "SwitchboardCore"]),
    ],
    swiftLanguageModes: [.v6]
)
