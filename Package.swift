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
    ],
    targets: [
        // C: declarations of the private IOAVService entry points. The symbols are exported by IOKit.
        .target(
            name: "IOAVServiceShim",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // C: IOUSBLib re-enumeration of the LG USB bridge (ported from the prototype's usbreset.c).
        .target(
            name: "USBReenumerate",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // Shared value types and protocols. No dependencies, no I/O.
        .target(name: "SwitchboardCore"),
        // Packet encoders/decoders, DDCTransport, VideoCableDDC, LGUSBBridge, FakeDDC, display enumeration.
        .target(
            name: "DDCKit",
            dependencies: ["IOAVServiceShim", "USBReenumerate", "SwitchboardCore"]
        ),
        // LGDualUp: the LGDualUpCommand whitelist and the verify-after-write flow.
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
    ],
    swiftLanguageModes: [.v6]
)
