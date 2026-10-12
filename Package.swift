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
        // Application layer (tracer bullet 3)
        .library(name: "StateStore", targets: ["StateStore"]),
        .library(name: "Actions", targets: ["Actions"]),
        // Menu bar app (tracer bullet 4)
        .library(name: "AppCore", targets: ["AppCore"]),
        .executable(name: "SwitchboardApp", targets: ["SwitchboardApp"]),
        // Local API (tracer bullet 5)
        .library(name: "LocalAPI", targets: ["LocalAPI"]),
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
            dependencies: ["Devices", "DDCKit", "SwitchboardCore", "ESP32Kit", "Actions", "StateStore", "LocalAPI"]
        ),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"]),
        .testTarget(name: "DDCKitTests", dependencies: ["DDCKit"]),
        .testTarget(name: "DevicesTests", dependencies: ["Devices", "DDCKit", "SwitchboardCore"]),
        // Networking (tracer bullet 6)
        .target(name: "TinyHTTP"),
        .target(name: "ESP32Kit", dependencies: ["TinyHTTP", "SwitchboardCore"]),
        .testTarget(name: "TinyHTTPTests", dependencies: ["TinyHTTP"]),
        .testTarget(name: "ESP32KitTests", dependencies: ["ESP32Kit", "TinyHTTP", "SwitchboardCore"]),
        // Application layer (tracer bullet 3)
        // Settings and the one observable model. No device dependencies.
        .target(name: "StateStore", dependencies: ["SwitchboardCore"]),
        // Action registry, macro model and store, macro runner, Runtime (composition root).
        .target(
            name: "Actions",
            dependencies: ["SwitchboardCore", "StateStore", "Devices", "DDCKit", "ESP32Kit"]
        ),
        .testTarget(name: "StateStoreTests", dependencies: ["StateStore", "SwitchboardCore"]),
        .testTarget(
            name: "ActionsTests",
            dependencies: ["Actions", "StateStore", "Devices", "DDCKit", "ESP32Kit", "SwitchboardCore"]
        ),
        // Menu bar app (tracer bullet 4)
        // Everything testable: URL scheme parsing, status glyph, run progress, the macro editor's
        // drafts and AppModel. No SwiftUI.
        .target(
            name: "AppCore",
            dependencies: ["Actions", "StateStore", "SwitchboardCore", "ESP32Kit"]
        ),
        // SwiftUI, thin: scenes and views over AppModel. Assembled into Switchboard.app by Scripts/make-app.sh.
        .executableTarget(
            name: "SwitchboardApp",
            dependencies: ["AppCore", "Actions", "StateStore", "SwitchboardCore", "ESP32Kit"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "Actions", "StateStore", "Devices", "DDCKit", "ESP32Kit", "SwitchboardCore"]
        ),
        // Local API (tracer bullet 5)
        // HTTP on 127.0.0.1 with a keychain bearer token, server-sent events, the Swift client the
        // CLI uses, and the Stream Deck `.command` wrapper generator.
        .target(
            name: "LocalAPI",
            dependencies: ["TinyHTTP", "Actions", "StateStore", "SwitchboardCore"]
        ),
        .testTarget(
            name: "LocalAPITests",
            dependencies: ["LocalAPI", "TinyHTTP", "Actions", "StateStore", "Devices", "DDCKit", "ESP32Kit", "SwitchboardCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
