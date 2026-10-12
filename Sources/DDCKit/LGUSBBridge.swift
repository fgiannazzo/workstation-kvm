import Foundation

/// Resolves the display the bridge must pair with. Production uses the IOAVService
/// enumeration by EDID name; tests inject a closure.
package typealias DisplayResolver = @Sendable () throws -> ExternalDisplay

/// The LG DualUp's USB HID bridge (brief, section 3, "USB HID bridge"): the channel LG's
/// OnScreen Control uses. Write-only: the bridge never answers reads, so `read(code:)` throws
/// `DDCError.readUnsupported` and every write is verified over the video cable by the caller.
///
/// Sending is fire-and-forget and exactly the prototype's verified `uset` path: open the
/// device, `IOHIDDeviceSetReport(output, report id 8, all 64 bytes)` for the first report, the
/// same for the follow-up report, close. No run loop, no input callbacks.
///
/// Pairing: the bridge's HID serial must identify the display (`BridgePairing.matches`). When
/// the display cannot be resolved (no video cable) the only bridge present is used, and more
/// than one is refused.
public actor LGUSBBridge: DDCTransport {
    /// LG Electronics.
    public static let vendorID = 0x043E
    /// "LG Monitor Controls".
    public static let productID = 0x9A39
    /// Vendor-defined usage page of the interface that carries DDC.
    public static let usagePage = 0xFF00
    public static let productString = "LG Monitor Controls"
    /// Every report goes out with this id (`buf[0]` of the framing), as hidapi sends it.
    public static let reportID: UInt8 = 0x08
    /// Interfaces whose output report is at least this long carry the 64-byte framing.
    public static let minimumOutputReportSize = 63
    /// `kIOReturnExclusiveAccess`: another client (a browser's WebUSB client, LG OnScreen Control)
    /// holds the device. Spelled out so the mapping is testable without IOKit.
    public static let exclusiveAccess: Int32 = Int32(bitPattern: 0xE000_02C5)
    private static let success: Int32 = 0

    public nonisolated let name: String
    /// Case-insensitive substring of the EDID name of the display to pair with, "SDQHD" for the DualUp.
    public let displayNameContains: String

    private let provider: any HIDDeviceProvider
    private let resolveDisplay: DisplayResolver

    /// Production: IOHIDManager for the bridge, IOAVService for the display.
    public init(displayNameContains: String = "SDQHD") {
        self.init(
            displayNameContains: displayNameContains,
            provider: IOHIDBridgeProvider(),
            resolveDisplay: { try IOAVServices.resolve(nameContains: displayNameContains).display }
        )
    }

    package init(displayNameContains: String, provider: any HIDDeviceProvider, resolveDisplay: @escaping DisplayResolver) {
        self.displayNameContains = displayNameContains
        self.name = "USB bridge (\(displayNameContains))"
        self.provider = provider
        self.resolveDisplay = resolveDisplay
    }

    /// Every LG bridge interface present, for `switchboardctl monitor bridge list`.
    public static func listDevices() throws -> [BridgeDevice] {
        try listDevices(provider: IOHIDBridgeProvider())
    }

    package static func listDevices(provider: any HIDDeviceProvider) throws -> [BridgeDevice] {
        try provider.matchingDevices().map(\.device)
    }

    /// The interface a write would go to right now, without opening it. Throws
    /// `DDCError.bridgeNotFound` with the reason when there is none.
    public func device() throws -> BridgeDevice {
        try choose(from: try provider.matchingDevices()).device
    }

    /// Sends the two 64-byte reports for one VCP set (`DDCPacket.usbBridgeReports`). Only
    /// source 0x51 exists on this transport. Never report success from this call: the bridge
    /// does not answer; read 0xD7 back over the video cable.
    public func write(_ write: VCPWrite) async throws {
        guard write.source == .standard else { throw DDCError.unsupportedSource(write.source) }
        let sink = try choose(from: try provider.matchingDevices())
        let (first, second) = DDCPacket.usbBridgeReports(set: write.code, value: write.value)

        let opened = sink.open()
        guard opened == Self.success else {
            if opened == Self.exclusiveAccess {
                throw DDCError.bridgeBusy(
                    "another client holds \(sink.device.product ?? "the LG bridge") (serial \(sink.device.serial ?? "unknown")) open exclusively, likely a browser's WebUSB client (Arc) or LG OnScreen Control; close it, or run `switchboardctl monitor bridge reset`"
                )
            }
            throw DDCError.ioKit(opened, operation: "IOHIDDeviceOpen")
        }
        defer { _ = sink.close() }

        for (label, report) in [("first report", first), ("follow-up report", second)] {
            let sent = sink.setOutputReport(id: Self.reportID, report)
            guard sent == Self.success else {
                throw DDCError.ioKit(sent, operation: "IOHIDDeviceSetReport(\(label))")
            }
        }
    }

    /// The bridge never answers reads (brief, section 3).
    public func read(code: UInt8) async throws -> VCPReply {
        throw DDCError.readUnsupported
    }

    // MARK: - Selection

    private func choose(from sinks: [any HIDReportSink]) throws -> any HIDReportSink {
        let display: ExternalDisplay?
        do {
            display = try resolveDisplay()
        } catch DDCError.displayNotFound {
            display = nil
        }
        let index = try BridgePairing.choose(among: sinks.map(\.device), display: display)
        return sinks[index]
    }
}
