/// The ESP32 state object, exactly the JSON shape from the brief, section 5:
/// `{ "hdmi": { "dualup": 1, "lg4k": 1, "samsung": 1 }, "usb": { "port": 1, "source": "aten" }, "uptime": 123 }`.
public struct ControllerState: Codable, Sendable, Equatable {
    /// Assumed HDMI input per display, 1 or 2. The OREI switches are not readable.
    public var hdmi: [DisplayID: Int]
    /// USB switch state; `port` comes from the ATEN `info` reply and is authoritative.
    public var usb: USB
    /// Controller uptime in seconds.
    public var uptime: Int

    public struct USB: Codable, Sendable, Equatable {
        public var port: Int
        public var source: String

        public init(port: Int, source: String) {
            self.port = port
            self.source = source
        }
    }

    public init(hdmi: [DisplayID: Int], usb: USB, uptime: Int) {
        self.hdmi = hdmi
        self.usb = usb
        self.uptime = uptime
    }

    private enum CodingKeys: String, CodingKey {
        case hdmi, usb, uptime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hdmi = try DisplayID.decode(from: container.superDecoder(forKey: .hdmi))
        usb = try container.decode(USB.self, forKey: .usb)
        uptime = try container.decode(Int.self, forKey: .uptime)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try DisplayID.encode(hdmi, to: container.superEncoder(forKey: .hdmi))
        try container.encode(usb, forKey: .usb)
        try container.encode(uptime, forKey: .uptime)
    }
}

/// Client for the ESP32 contract (brief, section 5). `ESP32Kit` implements it against the real
/// controller and against `MockESP32`.
public protocol ControllerClient: Sendable {
    func state() async throws -> ControllerState
    func selectHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState
    func resyncHDMI(_ display: DisplayID, input: Int) async throws -> ControllerState
    func selectUSB(port: Int) async throws -> ControllerState
    func events() -> AsyncStream<ControllerState>
}
