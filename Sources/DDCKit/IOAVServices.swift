import Foundation
import IOAVServiceShim
import IOKit

/// Owns one `IOAVServiceRef`. Not `Sendable` on purpose: an instance is created inside the
/// `VideoCableDDC` actor for a single operation and released with it. Nothing caches one.
final class AVService {
    /// `IOAVServiceRef` in C; Swift imports the typedef as `IOAVService` (= `CFTypeRef`).
    private let ref: IOAVService

    init?(service: io_service_t) {
        guard let ref = IOAVServiceCreateWithService(kCFAllocatorDefault, service) else { return nil }
        self.ref = ref
    }

    func copyEDID() throws -> Data {
        var edid: CFData?
        let rc = IOAVServiceCopyEDID(ref, &edid)
        guard rc == KERN_SUCCESS, let edid else {
            throw DDCError.ioKit(rc, operation: "IOAVServiceCopyEDID")
        }
        return edid as Data
    }

    func writeI2C(chip: UInt32, source: UInt8, bytes: [UInt8]) throws {
        var buffer = bytes
        let rc = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return KERN_INVALID_ARGUMENT }
            return IOAVServiceWriteI2C(ref, chip, UInt32(source), base, UInt32(raw.count))
        }
        guard rc == KERN_SUCCESS else {
            throw DDCError.ioKit(rc, operation: "IOAVServiceWriteI2C")
        }
    }

    func readI2C(chip: UInt32, source: UInt8, length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        let rc = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return KERN_INVALID_ARGUMENT }
            return IOAVServiceReadI2C(ref, chip, UInt32(source), base, UInt32(raw.count))
        }
        guard rc == KERN_SUCCESS else {
            throw DDCError.ioKit(rc, operation: "IOAVServiceReadI2C")
        }
        return buffer
    }
}

/// IOKit enumeration of `DCPAVServiceProxy` entries with `Location == External`.
enum IOAVServices {
    struct Entry {
        let display: ExternalDisplay
        let service: AVService
    }

    /// Enumerates every external display and opens an IOAVService for each. Called on every
    /// operation; never cache the result (indices change on re-enumeration).
    static func externalEntries() throws -> [Entry] {
        var iterator: io_iterator_t = 0
        let rc = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
        guard rc == KERN_SUCCESS else {
            throw DDCError.ioKit(rc, operation: "IOServiceGetMatchingServices(DCPAVServiceProxy)")
        }
        defer { IOObjectRelease(iterator) }

        var entries: [Entry] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard isExternal(service), let av = AVService(service: service) else { continue }
            let display: ExternalDisplay
            if let edid = try? av.copyEDID(), let parsed = try? EDID.parse(edid) {
                display = ExternalDisplay(edid: parsed)
            } else {
                display = .withoutEDID()
            }
            entries.append(Entry(display: display, service: av))
        }
        return entries
    }

    /// The first external display whose EDID name contains `substring` (case-insensitive).
    static func resolve(nameContains substring: String) throws -> Entry {
        guard let entry = try externalEntries().first(where: { $0.display.nameContains(substring) }) else {
            throw DDCError.displayNotFound(substring)
        }
        return entry
    }

    private static func isExternal(_ service: io_service_t) -> Bool {
        // IOKitLib.h annotates this CF_RETURNS_RETAINED but is not an audited header, so Swift
        // hands back Unmanaged; taking the retained value balances the +1.
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0) else {
            return false
        }
        let property = unmanaged.takeRetainedValue()
        guard CFGetTypeID(property) == CFStringGetTypeID() else { return false }
        return (property as! CFString) as String == "External"
    }
}
