/// One HID interface as IOKit describes it (`IOHIDDeviceGetProperty`). Pure data, so the
/// CLI can list bridges and tests can script them.
public struct BridgeDevice: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let vendorID: Int
    public let productID: Int
    /// `kIOHIDProductKey`, "LG Monitor Controls" on the DualUp's bridge.
    public let product: String?
    /// `kIOHIDSerialNumberKey`. Equals the monitor's EDID serial, which pairs bridge and display.
    public let serial: String?
    /// `kIOHIDPrimaryUsagePageKey`, 0xFF00 (vendor-defined) on the bridge.
    public let usagePage: Int
    /// `kIOHIDMaxOutputReportSizeKey`. The interface that carries DDC has 64-byte reports.
    public let maxOutputReportSize: Int

    public init(vendorID: Int, productID: Int, product: String?, serial: String?, usagePage: Int, maxOutputReportSize: Int) {
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.serial = serial
        self.usagePage = usagePage
        self.maxOutputReportSize = maxOutputReportSize
    }

    public var description: String {
        var parts = [
            "pid 0x\(String(productID, radix: 16, uppercase: true).leftPadded(to: 4))",
            product ?? "(no product string)",
            "usage page 0x\(String(usagePage, radix: 16, uppercase: true).leftPadded(to: 4))",
            "max output report \(maxOutputReportSize)",
        ]
        parts.append("serial \(serial.flatMap { $0.isEmpty ? nil : $0 } ?? "(none)")")
        return parts.joined(separator: "  ")
    }
}

/// One HID interface the bridge can send output reports to. The production implementation
/// wraps an `IOHIDDeviceRef`; tests use a fake. Every call is synchronous and returns the raw
/// `IOReturn`, so the mapping to `DDCError` lives in `LGUSBBridge` where it is unit-tested.
package protocol HIDReportSink: AnyObject {
    var device: BridgeDevice { get }
    /// `IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone)`.
    func open() -> Int32
    /// `IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, id, bytes, bytes.count)`.
    func setOutputReport(id: UInt8, _ bytes: [UInt8]) -> Int32
    /// `IOHIDDeviceClose(device, kIOHIDOptionsTypeNone)`.
    func close() -> Int32
}

/// Enumerates the HID interfaces that match LG's vendor id and the bridge's product id. The
/// production implementation is `IOHIDBridgeProvider`; tests inject a fake.
package protocol HIDDeviceProvider {
    /// Every matching interface in IOKit order. Throws `DDCError.ioKit` when enumeration itself fails.
    func matchingDevices() throws -> [any HIDReportSink]
}

/// How `LGUSBBridge` chooses which HID interface to write to. Pure functions, unit-tested.
public enum BridgePairing {
    /// True when the bridge's HID serial identifies `display`: it equals the EDID serial string
    /// (descriptor 0xFF), or it is the numeric EDID serial (bytes 12-15) rendered as decimal or
    /// as hex (with or without a `0x` prefix). Comparison ignores case and surrounding
    /// whitespace. A nil or empty HID serial never matches, and a numeric serial of 0 is not
    /// evidence of anything.
    public static func matches(hidSerial: String?, display: ExternalDisplay) -> Bool {
        guard let hidSerial else { return false }
        let serial = hidSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty else { return false }

        if let serialString = display.serialString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serialString.isEmpty, serialString.caseInsensitiveCompare(serial) == .orderedSame {
            return true
        }
        guard display.serial != 0 else { return false }
        if let decimal = UInt32(serial, radix: 10), decimal == display.serial { return true }
        var hexDigits = serial.lowercased()
        if hexDigits.hasPrefix("0x") { hexDigits.removeFirst(2) }
        if let hex = UInt32(hexDigits, radix: 16), hex == display.serial { return true }
        return false
    }

    /// Picks the interface to write to. `devices` is what the provider enumerated (already
    /// filtered to LG's vendor id); `display` is the resolved DualUp, or nil when the video
    /// cable could not resolve it. Returns the index into `devices`.
    ///
    /// Rules, in order: keep only product 0x9A39 on usage page 0xFF00; when the display is
    /// known keep only the interfaces whose serial pairs with it; when it is not, accept the
    /// bridge only if every candidate carries the same serial (one physical bridge), otherwise
    /// refuse rather than guess; among what is left prefer the interface whose output report
    /// is at least 63 bytes (the DDC channel), falling back to the first.
    public static func choose(among devices: [BridgeDevice], display: ExternalDisplay?) throws -> Int {
        let candidates = devices.indices.filter {
            devices[$0].productID == LGUSBBridge.productID && devices[$0].usagePage == LGUSBBridge.usagePage
        }
        guard !candidates.isEmpty else {
            if devices.isEmpty {
                throw DDCError.bridgeNotFound("no HID device with vendor 0x043E, product 0x9A39")
            }
            let seen = devices.map(\.description).joined(separator: "; ")
            throw DDCError.bridgeNotFound("\(devices.count) LG HID device(s) present but none is product 0x9A39 on usage page 0xFF00: \(seen)")
        }

        let paired: [Int]
        if let display {
            paired = candidates.filter { matches(hidSerial: devices[$0].serial, display: display) }
            guard !paired.isEmpty else {
                let serials = candidates.map { devices[$0].serial ?? "(none)" }.joined(separator: ", ")
                throw DDCError.bridgeNotFound(
                    "\(candidates.count) LG Monitor Controls interface(s) found (serial \(serials)) but none pairs with display \(display.name) (serial \(display.serialHex)\(display.serialString.map { ", serial string \($0)" } ?? ""))"
                )
            }
        } else {
            let serials = Set(candidates.map { devices[$0].serial ?? "" })
            guard serials.count <= 1 else {
                throw DDCError.bridgeNotFound(
                    "the display could not be resolved over the video cable and more than one LG bridge is present (serials \(serials.sorted().joined(separator: ", "))); cannot tell which one is the DualUp"
                )
            }
            paired = candidates
        }

        return paired.first { devices[$0].maxOutputReportSize >= LGUSBBridge.minimumOutputReportSize } ?? paired[0]
    }
}
