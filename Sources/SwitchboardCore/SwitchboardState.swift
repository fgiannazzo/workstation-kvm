import Foundation

/// The one observable model, published by `StateStore` and served by `GET /state`
/// (`docs/API.md`). Every field defaults to "unknown" so a freshly launched app never claims
/// a state it has not read.
public struct SwitchboardState: Codable, Sendable, Equatable {
    public var pbp: PBPState = .unknown
    public var mainInput: MainInput = .unknown
    public var usbPort: Int? = nil
    /// Assumed HDMI input per display; keys may be missing. Encodes as a JSON object.
    public var hdmiInput: [DisplayID: Int] = [:]
    public var controllerReachable: Bool = false
    public var dualUpReachable: Bool = false
    public var lastError: String? = nil
    public var updatedAt: Date = .distantPast

    public init(
        pbp: PBPState = .unknown,
        mainInput: MainInput = .unknown,
        usbPort: Int? = nil,
        hdmiInput: [DisplayID: Int] = [:],
        controllerReachable: Bool = false,
        dualUpReachable: Bool = false,
        lastError: String? = nil,
        updatedAt: Date = .distantPast
    ) {
        self.pbp = pbp
        self.mainInput = mainInput
        self.usbPort = usbPort
        self.hdmiInput = hdmiInput
        self.controllerReachable = controllerReachable
        self.dualUpReachable = dualUpReachable
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case pbp, mainInput, usbPort, hdmiInput, controllerReachable, dualUpReachable, lastError, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pbp = try container.decodeIfPresent(PBPState.self, forKey: .pbp) ?? .unknown
        mainInput = try container.decodeIfPresent(MainInput.self, forKey: .mainInput) ?? .unknown
        usbPort = try container.decodeIfPresent(Int.self, forKey: .usbPort)
        if container.contains(.hdmiInput), try !container.decodeNil(forKey: .hdmiInput) {
            hdmiInput = try DisplayID.decode(from: container.superDecoder(forKey: .hdmiInput))
        } else {
            hdmiInput = [:]
        }
        controllerReachable = try container.decodeIfPresent(Bool.self, forKey: .controllerReachable) ?? false
        dualUpReachable = try container.decodeIfPresent(Bool.self, forKey: .dualUpReachable) ?? false
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pbp, forKey: .pbp)
        try container.encode(mainInput, forKey: .mainInput)
        try container.encode(usbPort, forKey: .usbPort)          // null when unknown, per docs/API.md
        try DisplayID.encode(hdmiInput, to: container.superEncoder(forKey: .hdmiInput))
        try container.encode(controllerReachable, forKey: .controllerReachable)
        try container.encode(dualUpReachable, forKey: .dualUpReachable)
        try container.encode(lastError, forKey: .lastError)      // null when clear, per docs/API.md
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
