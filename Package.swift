// swift-tools-version: 6.0
import Foundation
import MachO
import PackageDescription

// Swift Testing's macro plugin ships in `<toolchain>/usr/lib/swift/host/plugins/testing`. The
// Command Line Tools' SwiftPM (Swift 6.4, Swift Build backend) does not hand that directory to
// the compiler, so every `@Test`/`@Suite` fails with "plugin for module 'TestingMacros' not
// found" and `swift test` cannot build. Xcode's toolchain adds the path itself; passing it
// again there is harmless. We find the toolchain that is evaluating this manifest through the
// PackageDescription library it loaded, and add the path to the test targets only.
let testingPluginSettings: [SwiftSetting] = {
    let marker = "/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"
    for index in 0..<_dyld_image_count() {
        guard let cPath = _dyld_get_image_name(index) else { continue }
        let path = String(cString: cPath)
        guard path.hasSuffix(marker) else { continue }
        let plugins = String(path.dropLast(marker.count)) + "/lib/swift/host/plugins/testing"
        guard FileManager.default.fileExists(atPath: plugins) else { return [] }
        return [.unsafeFlags(["-plugin-path", plugins])]
    }
    return []
}()

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
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"], swiftSettings: testingPluginSettings),
        .testTarget(name: "DDCKitTests", dependencies: ["DDCKit"], swiftSettings: testingPluginSettings),
        .testTarget(name: "DevicesTests", dependencies: ["Devices", "DDCKit", "SwitchboardCore"], swiftSettings: testingPluginSettings),
    ],
    swiftLanguageModes: [.v6]
)
