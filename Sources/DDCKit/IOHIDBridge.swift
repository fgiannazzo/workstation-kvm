import Foundation
import IOKit
import IOKit.hid

/// Keeps the `IOHIDManager` alive for as long as any device taken from it is in use, and
/// closes it when the last one goes away. Not `Sendable`: it lives inside one `LGUSBBridge`
/// call and never crosses an isolation boundary.
final class IOHIDManagerSession {
    let manager: IOHIDManager

    init(manager: IOHIDManager) {
        self.manager = manager
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

/// Thin adapter over one `IOHIDDeviceRef`. Every method is a single IOKit call returning the
/// raw `IOReturn`; `LGUSBBridge` decides what the codes mean.
final class IOHIDReportSink: HIDReportSink {
    let device: BridgeDevice
    private let ref: IOHIDDevice
    private let session: IOHIDManagerSession

    init(ref: IOHIDDevice, session: IOHIDManagerSession) {
        self.ref = ref
        self.session = session
        self.device = BridgeDevice(
            vendorID: Self.intProperty(ref, kIOHIDVendorIDKey) ?? 0,
            productID: Self.intProperty(ref, kIOHIDProductIDKey) ?? 0,
            product: Self.stringProperty(ref, kIOHIDProductKey),
            serial: Self.stringProperty(ref, kIOHIDSerialNumberKey),
            usagePage: Self.intProperty(ref, kIOHIDPrimaryUsagePageKey) ?? 0,
            maxOutputReportSize: Self.intProperty(ref, kIOHIDMaxOutputReportSizeKey) ?? 0
        )
    }

    func open() -> Int32 {
        IOHIDDeviceOpen(ref, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setOutputReport(id: UInt8, _ bytes: [UInt8]) -> Int32 {
        bytes.withUnsafeBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(ref, kIOHIDReportTypeOutput, CFIndex(id), base, CFIndex(buffer.count))
        }
    }

    func close() -> Int32 {
        IOHIDDeviceClose(ref, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var number = 0
        let cfNumber = value as! CFNumber
        guard CFNumberGetValue(cfNumber, .nsIntegerType, &number) else { return nil }
        return number
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }
}

/// Enumerates LG bridge interfaces through `IOHIDManager`, the way the prototype's `lgusb.m`
/// does: match on vendor and product, open the manager (non-exclusively; that is the verified
/// sequence), copy the device set. The manager stays open until every returned sink is gone.
struct IOHIDBridgeProvider: HIDDeviceProvider {
    func matchingDevices() throws -> [any HIDReportSink] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: LGUSBBridge.vendorID,
            kIOHIDProductIDKey: LGUSBBridge.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            throw DDCError.ioKit(opened, operation: "IOHIDManagerOpen")
        }
        let session = IOHIDManagerSession(manager: manager)

        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        let count = CFSetGetCount(set)
        guard count > 0 else { return [] }
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(set, &values)
        return values.compactMap { pointer -> IOHIDReportSink? in
            guard let pointer else { return nil }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            return IOHIDReportSink(ref: device, session: session)
        }
    }
}
