import DDCKit
import Foundation
import Synchronization
import Testing

// MARK: - Fakes

/// Scripted stand-in for one `IOHIDDeviceRef`. Records every call in order so a test can assert
/// the exact open / report / report / close sequence. `Sendable` through a mutex so the test
/// can inspect it after handing it to the actor.
final class FakeSink: HIDReportSink, Sendable {
    enum Event: Equatable, Sendable {
        case open
        case report(id: UInt8, bytes: [UInt8])
        case close
    }

    let device: BridgeDevice
    private let openResult: Int32
    private let reportResult: Int32
    private let log = Mutex<[Event]>([])

    init(device: BridgeDevice, openResult: Int32 = 0, reportResult: Int32 = 0) {
        self.device = device
        self.openResult = openResult
        self.reportResult = reportResult
    }

    var events: [Event] { log.withLock { $0 } }

    func open() -> Int32 {
        log.withLock { $0.append(.open) }
        return openResult
    }

    func setOutputReport(id: UInt8, _ bytes: [UInt8]) -> Int32 {
        log.withLock { $0.append(.report(id: id, bytes: bytes)) }
        return reportResult
    }

    func close() -> Int32 {
        log.withLock { $0.append(.close) }
        return 0
    }
}

struct FakeProvider: HIDDeviceProvider, Sendable {
    var sinks: [FakeSink] = []
    var error: DDCError? = nil

    func matchingDevices() throws -> [any HIDReportSink] {
        if let error { throw error }
        return sinks
    }
}

// MARK: - Fixtures

let dualUpDisplay = ExternalDisplay(
    name: "LG SDQHD", serial: 0x0001E240, serialString: "312NTABC1234", manufacturer: "GSM", productCode: 0x7708, edid: Data()
)

func bridgeDevice(
    serial: String? = "312NTABC1234",
    maxOutput: Int = 64,
    productID: Int = LGUSBBridge.productID,
    usagePage: Int = LGUSBBridge.usagePage,
    product: String? = LGUSBBridge.productString
) -> BridgeDevice {
    BridgeDevice(vendorID: LGUSBBridge.vendorID, productID: productID, product: product, serial: serial, usagePage: usagePage, maxOutputReportSize: maxOutput)
}

/// A bridge over fake sinks. `display` nil models "no video cable": the resolver throws
/// `displayNotFound`, as `IOAVServices.resolve` does.
func makeBridge(_ sinks: [FakeSink], display: ExternalDisplay? = dualUpDisplay, providerError: DDCError? = nil) -> LGUSBBridge {
    LGUSBBridge(
        displayNameContains: "SDQHD",
        provider: FakeProvider(sinks: sinks, error: providerError),
        resolveDisplay: {
            guard let display else { throw DDCError.displayNotFound("SDQHD") }
            return display
        }
    )
}

func thrownDDCError(_ body: () async throws -> Void) async -> DDCError? {
    do {
        try await body()
        return nil
    } catch let error as DDCError {
        return error
    } catch {
        return nil
    }
}

// MARK: - BridgePairing.matches

@Suite("BridgePairing.matches")
struct BridgePairingMatchesTests {
    @Test("HID serial pairs with the EDID serial string, or the numeric serial as decimal or hex", arguments: [
        ("312NTABC1234", true),          // serial string, exact
        ("312ntabc1234", true),          // serial string, case-insensitive
        ("  312NTABC1234\n", true),      // surrounding whitespace ignored
        ("123456", true),                // 0x0001E240 in decimal
        ("1E240", true),                 // hex, no prefix
        ("1e240", true),                 // hex, lower case
        ("0x1E240", true),               // hex, 0x prefix
        ("0001E240", true),              // hex, zero padded
        ("123457", false),               // off by one
        ("1E241", false),
        ("312NTABC1235", false),         // another monitor's serial string
        ("ABC", false),                  // not a number, not the string
        ("", false),
        (nil, false),
    ] as [(String?, Bool)])
    func matches(hidSerial: String?, expected: Bool) {
        #expect(BridgePairing.matches(hidSerial: hidSerial, display: dualUpDisplay) == expected)
    }

    @Test("a display without serial information pairs with nothing")
    func nothingToPairWith() {
        let blank = ExternalDisplay(name: "LG SDQHD", serial: 0, serialString: nil, manufacturer: "GSM", productCode: 0x7708, edid: Data())
        #expect(!BridgePairing.matches(hidSerial: "0", display: blank))
        #expect(!BridgePairing.matches(hidSerial: "0x0", display: blank))
        #expect(!BridgePairing.matches(hidSerial: "", display: blank))
        let noEDID = ExternalDisplay.withoutEDID()
        #expect(!BridgePairing.matches(hidSerial: "0", display: noEDID))
    }

    @Test("a display with only a numeric serial still pairs by number")
    func numericOnly() {
        let numeric = ExternalDisplay(name: "LG SDQHD", serial: 42, serialString: nil, manufacturer: "GSM", productCode: 1, edid: Data())
        #expect(BridgePairing.matches(hidSerial: "42", display: numeric))
        #expect(BridgePairing.matches(hidSerial: "2A", display: numeric))
        #expect(!BridgePairing.matches(hidSerial: "43", display: numeric))
    }
}

// MARK: - BridgePairing.choose

@Suite("BridgePairing.choose")
struct BridgePairingChooseTests {
    @Test("prefers the interface with a 64-byte output report among several of the same bridge")
    func prefers64ByteInterface() throws {
        let devices = [bridgeDevice(maxOutput: 8), bridgeDevice(maxOutput: 64), bridgeDevice(maxOutput: 8)]
        #expect(try BridgePairing.choose(among: devices, display: dualUpDisplay) == 1)
        #expect(try BridgePairing.choose(among: devices, display: nil) == 1)
    }

    @Test("63 counts as the DDC interface (kIOHIDMaxOutputReportSizeKey may exclude the id byte)")
    func sixtyThree() throws {
        let devices = [bridgeDevice(maxOutput: 8), bridgeDevice(maxOutput: 63)]
        #expect(try BridgePairing.choose(among: devices, display: dualUpDisplay) == 1)
    }

    @Test("falls back to the first paired interface when none advertises 64 bytes")
    func fallsBackToFirst() throws {
        let devices = [bridgeDevice(maxOutput: 8), bridgeDevice(maxOutput: 8)]
        #expect(try BridgePairing.choose(among: devices, display: dualUpDisplay) == 0)
    }

    @Test("pairs by serial when two LG bridges are present")
    func pairsBySerial() throws {
        let devices = [bridgeDevice(serial: "999NTOTHER00"), bridgeDevice(serial: "312NTABC1234"), bridgeDevice(serial: "123456", maxOutput: 8)]
        #expect(try BridgePairing.choose(among: devices, display: dualUpDisplay) == 1)
    }

    @Test("without a display, the only bridge is used")
    func singleBridgeWithoutDisplay() throws {
        #expect(try BridgePairing.choose(among: [bridgeDevice(serial: "whatever")], display: nil) == 0)
        #expect(try BridgePairing.choose(among: [bridgeDevice(serial: nil)], display: nil) == 0)
    }

    @Test("without a display, two bridges with different serials are refused and the error says so")
    func twoBridgesWithoutDisplay() {
        let devices = [bridgeDevice(serial: "AAA"), bridgeDevice(serial: "BBB")]
        #expect(throws: DDCError.self) { try BridgePairing.choose(among: devices, display: nil) }
        do {
            _ = try BridgePairing.choose(among: devices, display: nil)
            Issue.record("expected bridgeNotFound")
        } catch let DDCError.bridgeNotFound(detail) {
            #expect(detail.contains("more than one LG bridge"))
            #expect(detail.contains("AAA"))
            #expect(detail.contains("BBB"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("no devices at all is bridgeNotFound with the brief's hint in the description")
    func noDevices() {
        do {
            _ = try BridgePairing.choose(among: [], display: dualUpDisplay)
            Issue.record("expected bridgeNotFound")
        } catch let error as DDCError {
            guard case .bridgeNotFound(let detail) = error else { Issue.record("unexpected \(error)"); return }
            #expect(detail.contains("0x043E"))
            #expect(detail.contains("0x9A39"))
            #expect(error.description.contains("USB upstream on the Studio"))
            #expect(error.description.contains("monitor bridge reset"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("other LG HID interfaces (wrong product or usage page) are never chosen")
    func filtersProductAndUsagePage() {
        let devices = [bridgeDevice(productID: 0x9A40), bridgeDevice(usagePage: 0x000C)]
        do {
            _ = try BridgePairing.choose(among: devices, display: dualUpDisplay)
            Issue.record("expected bridgeNotFound")
        } catch let DDCError.bridgeNotFound(detail) {
            #expect(detail.contains("none is product 0x9A39 on usage page 0xFF00"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("a bridge that does not pair with the resolved display is refused")
    func unpairedBridgeRefused() {
        do {
            _ = try BridgePairing.choose(among: [bridgeDevice(serial: "999NTOTHER00")], display: dualUpDisplay)
            Issue.record("expected bridgeNotFound")
        } catch let DDCError.bridgeNotFound(detail) {
            #expect(detail.contains("none pairs with display LG SDQHD"))
            #expect(detail.contains("0x0001E240"))
            #expect(detail.contains("312NTABC1234"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

// MARK: - LGUSBBridge

@Suite("LGUSBBridge")
struct LGUSBBridgeTests {
    @Test("sends exactly the two usbBridgeReports with report id 8 and 64 bytes, open before, close after")
    func sendsTwoReports() async throws {
        let sink = FakeSink(device: bridgeDevice())
        let bridge = makeBridge([sink])

        try await bridge.write(VCPWrite(code: 0xD7, value: 0, source: .standard))

        let (first, second) = DDCPacket.usbBridgeReports(set: 0xD7, value: 0)
        #expect(first.count == 64 && second.count == 64)
        #expect(sink.events == [.open, .report(id: 8, bytes: first), .report(id: 8, bytes: second), .close])
        #expect(Array(first[0..<15]) == [0x08, 0x01, 0x55, 0x03, 0x07, 0x00, 0x03, 0x37, 0x51, 0x84, 0x03, 0xD7, 0x00, 0x00, 0x6F])
        #expect(Array(second[0..<15]) == [0x08, 0x02, 0x55, 0x04, 0x0B, 0x00, 0x0B, 0x37, 0x51, 0x84, 0x03, 0xD7, 0x00, 0x00, 0x6F])
    }

    @Test("the reports carry the write's value (0xD7 = 1 encodes 84 03 D7 00 01 6E)")
    func reportsCarryValue() async throws {
        let sink = FakeSink(device: bridgeDevice())
        try await makeBridge([sink]).write(VCPWrite(code: 0xD7, value: 1))
        guard case .report(_, let bytes) = sink.events[1] else { Issue.record("no first report"); return }
        #expect(Array(bytes[8..<15]) == [0x51, 0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E])
    }

    @Test("kIOReturnExclusiveAccess on open maps to bridgeBusy naming the likely holder; nothing is sent")
    func exclusiveAccess() async {
        let sink = FakeSink(device: bridgeDevice(), openResult: LGUSBBridge.exclusiveAccess)
        let error = await thrownDDCError { try await makeBridge([sink]).write(VCPWrite(code: 0xD7, value: 0)) }

        guard case .bridgeBusy(let detail)? = error else { Issue.record("expected bridgeBusy, got \(String(describing: error))"); return }
        #expect(detail.contains("WebUSB"))
        #expect(detail.contains("312NTABC1234"))
        #expect(error?.description.contains("busy") == true)
        #expect(sink.events == [.open])
    }

    @Test("the exclusive-access code is IOKit's kIOReturnExclusiveAccess")
    func exclusiveAccessCode() {
        #expect(UInt32(bitPattern: LGUSBBridge.exclusiveAccess) == 0xE000_02C5)
    }

    @Test("any other open failure is ioKit(IOHIDDeviceOpen)")
    func otherOpenFailure() async {
        let sink = FakeSink(device: bridgeDevice(), openResult: Int32(bitPattern: 0xE000_02BD))
        let error = await thrownDDCError { try await makeBridge([sink]).write(VCPWrite(code: 0xD7, value: 0)) }
        #expect(error == .ioKit(Int32(bitPattern: 0xE000_02BD), operation: "IOHIDDeviceOpen"))
        #expect(sink.events == [.open])
    }

    @Test("a failed SetReport is ioKit(IOHIDDeviceSetReport) and the device is still closed")
    func setReportFailure() async {
        let sink = FakeSink(device: bridgeDevice(), reportResult: -1)
        let error = await thrownDDCError { try await makeBridge([sink]).write(VCPWrite(code: 0xD7, value: 0)) }
        guard case .ioKit(-1, let operation)? = error else { Issue.record("expected ioKit, got \(String(describing: error))"); return }
        #expect(operation.contains("IOHIDDeviceSetReport"))
        #expect(sink.events.count == 3)
        #expect(sink.events.last == .close)
    }

    @Test("picks the 64-byte interface among several and leaves the others untouched")
    func picks64ByteInterface() async throws {
        let small = FakeSink(device: bridgeDevice(maxOutput: 8))
        let big = FakeSink(device: bridgeDevice(maxOutput: 64))
        let other = FakeSink(device: bridgeDevice(maxOutput: 8))

        try await makeBridge([small, big, other]).write(VCPWrite(code: 0xD7, value: 0))

        #expect(small.events.isEmpty)
        #expect(other.events.isEmpty)
        #expect(big.events.count == 4)
        #expect(big.events.first == .open)
    }

    @Test("pairs by serial: another LG bridge never receives the write")
    func pairsBySerial() async throws {
        let other = FakeSink(device: bridgeDevice(serial: "999NTOTHER00"))
        let mine = FakeSink(device: bridgeDevice(serial: "123456"))   // 0x0001E240 in decimal

        try await makeBridge([other, mine]).write(VCPWrite(code: 0xD7, value: 0))

        #expect(other.events.isEmpty)
        #expect(mine.events.count == 4)
    }

    @Test("without the video cable, the only bridge is used")
    func fallsBackToOnlyBridge() async throws {
        let only = FakeSink(device: bridgeDevice(serial: "anything"))
        try await makeBridge([only], display: nil).write(VCPWrite(code: 0xD7, value: 0))
        #expect(only.events.count == 4)
    }

    @Test("without the video cable, two different bridges are refused before anything is opened")
    func refusesAmbiguityWithoutDisplay() async {
        let a = FakeSink(device: bridgeDevice(serial: "AAA"))
        let b = FakeSink(device: bridgeDevice(serial: "BBB"))
        let error = await thrownDDCError { try await makeBridge([a, b], display: nil).write(VCPWrite(code: 0xD7, value: 0)) }
        guard case .bridgeNotFound(let detail)? = error else { Issue.record("expected bridgeNotFound"); return }
        #expect(detail.contains("more than one"))
        #expect(a.events.isEmpty && b.events.isEmpty)
    }

    @Test("no bridge present is bridgeNotFound")
    func noBridge() async {
        let error = await thrownDDCError { try await makeBridge([]).write(VCPWrite(code: 0xD7, value: 0)) }
        guard case .bridgeNotFound? = error else { Issue.record("expected bridgeNotFound"); return }
    }

    @Test("an enumeration failure propagates as ioKit")
    func providerFailure() async {
        let error = await thrownDDCError {
            try await makeBridge([], providerError: .ioKit(-5, operation: "IOHIDManagerOpen")).write(VCPWrite(code: 0xD7, value: 0))
        }
        #expect(error == .ioKit(-5, operation: "IOHIDManagerOpen"))
    }

    @Test("a display-resolution failure other than displayNotFound propagates")
    func resolverFailurePropagates() async {
        let sink = FakeSink(device: bridgeDevice())
        let bridge = LGUSBBridge(
            displayNameContains: "SDQHD",
            provider: FakeProvider(sinks: [sink]),
            resolveDisplay: { throw DDCError.ioKit(-7, operation: "IOServiceGetMatchingServices(DCPAVServiceProxy)") }
        )
        let error = await thrownDDCError { try await bridge.write(VCPWrite(code: 0xD7, value: 0)) }
        #expect(error == .ioKit(-7, operation: "IOServiceGetMatchingServices(DCPAVServiceProxy)"))
        #expect(sink.events.isEmpty)
    }

    @Test("read throws readUnsupported: the bridge never answers")
    func readUnsupported() async {
        let sink = FakeSink(device: bridgeDevice())
        let bridge = makeBridge([sink])
        await #expect(throws: DDCError.readUnsupported) { try await bridge.read(code: 0xD7) }
        #expect(sink.events.isEmpty)
    }

    @Test("only source 0x51 exists on the bridge: a side-channel write is refused before anything is opened")
    func refusesSideChannel() async {
        let sink = FakeSink(device: bridgeDevice())
        let error = await thrownDDCError { try await makeBridge([sink]).write(VCPWrite(code: 0xD7, value: 1, source: .lgSideChannel)) }
        #expect(error == .unsupportedSource(.lgSideChannel))
        #expect(error?.description.contains("0x50") == true)
        #expect(sink.events.isEmpty)
    }

    @Test("device() reports the interface a write would use, without opening it")
    func device() async throws {
        let small = FakeSink(device: bridgeDevice(maxOutput: 8))
        let big = FakeSink(device: bridgeDevice(maxOutput: 64))
        let chosen = try await makeBridge([small, big]).device()
        #expect(chosen == big.device)
        #expect(small.events.isEmpty && big.events.isEmpty)
    }

    @Test("listDevices returns every LG interface in enumeration order, unfiltered")
    func listDevices() throws {
        let devices = [bridgeDevice(maxOutput: 8, usagePage: 0x000C), bridgeDevice(maxOutput: 64), bridgeDevice(serial: "other", productID: 0x9A40)]
        let listed = try LGUSBBridge.listDevices(provider: FakeProvider(sinks: devices.map { FakeSink(device: $0) }))
        #expect(listed == devices)
    }

    @Test("name and matching constants")
    func constants() {
        #expect(makeBridge([]).name == "USB bridge (SDQHD)")
        #expect(LGUSBBridge.vendorID == 0x043E)
        #expect(LGUSBBridge.productID == 0x9A39)
        #expect(LGUSBBridge.usagePage == 0xFF00)
        #expect(LGUSBBridge.productString == "LG Monitor Controls")
        #expect(LGUSBBridge.reportID == 8)
        #expect(LGUSBBridge.minimumOutputReportSize == 63)
    }
}

// MARK: - BridgeDevice, UnavailableTransport, DDCError

@Suite("BridgeDevice")
struct BridgeDeviceTests {
    @Test("description lists pid, product, usage page, max output report and serial")
    func description() {
        let text = bridgeDevice().description
        #expect(text.contains("pid 0x9A39"))
        #expect(text.contains("LG Monitor Controls"))
        #expect(text.contains("usage page 0xFF00"))
        #expect(text.contains("max output report 64"))
        #expect(text.contains("serial 312NTABC1234"))
        #expect(bridgeDevice(serial: nil, product: nil).description.contains("serial (none)"))
        #expect(bridgeDevice(serial: "", product: nil).description.contains("(no product string)"))
    }
}

@Suite("UnavailableTransport")
struct UnavailableTransportTests {
    @Test("writes throw bridgeNotFound with the reason; reads throw readUnsupported")
    func throwsEverything() async {
        let transport = UnavailableTransport(name: "USB bridge (not configured)", reason: "no bridge configured")
        #expect(transport.name == "USB bridge (not configured)")
        await #expect(throws: DDCError.bridgeNotFound("no bridge configured")) {
            try await transport.write(VCPWrite(code: 0xD7, value: 0))
        }
        await #expect(throws: DDCError.readUnsupported) { try await transport.read(code: 0xD7) }
    }
}

@Suite("DDCError bridge cases")
struct DDCErrorBridgeTests {
    @Test("descriptions carry the detail and, for not found, the brief's hint")
    func descriptions() {
        let notFound = DDCError.bridgeNotFound("no HID device with vendor 0x043E, product 0x9A39")
        #expect(notFound.description.contains("LG USB bridge not found"))
        #expect(notFound.description.contains("0x9A39"))
        #expect(notFound.description.contains(DDCError.bridgeHint))
        #expect(DDCError.bridgeHint.contains("USB upstream on the Studio"))
        #expect(DDCError.bridgeHint.contains("selected in the OSD"))
        #expect(DDCError.bridgeHint.contains("monitor bridge reset"))

        let busy = DDCError.bridgeBusy("Arc holds it")
        #expect(busy.description == "LG USB bridge is busy: Arc holds it")

        #expect(DDCError.unsupportedSource(.lgSideChannel).description.contains("0x50"))
    }

    @Test("hexString writes bytes the way the design document does")
    func hexString() {
        #expect(DDCPacket.hexString([0x84, 0x03, 0xD7, 0x00, 0x01, 0x6E]) == "84 03 D7 00 01 6E")
        #expect(DDCPacket.hexString([]) == "")
        #expect(DDCPacket.hexString([0x0B]) == "0B")
    }
}
