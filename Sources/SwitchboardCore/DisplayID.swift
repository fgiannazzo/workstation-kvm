/// The three displays on the desk, as named by the ESP32 contract (brief, section 5).
public enum DisplayID: String, Codable, CaseIterable, Sendable, Hashable {
    case dualup
    case lg4k
    case samsung
}

extension DisplayID {
    /// Encodes `[DisplayID: Int]` as a JSON object keyed by the raw string ("dualup", "lg4k",
    /// "samsung"), never as an array. Used by the hand-written Codable conformances in this module.
    static func encode(_ map: [DisplayID: Int], to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DisplayIDKey.self)
        for display in DisplayID.allCases {
            if let value = map[display] {
                try container.encode(value, forKey: DisplayIDKey(display))
            }
        }
    }

    /// Decodes the object written by `encode(_:to:)`. Unknown keys are ignored so a newer
    /// controller can add displays without breaking older clients.
    static func decode(from decoder: any Decoder) throws -> [DisplayID: Int] {
        let container = try decoder.container(keyedBy: DisplayIDKey.self)
        var map: [DisplayID: Int] = [:]
        for key in container.allKeys {
            guard let display = DisplayID(rawValue: key.stringValue) else { continue }
            map[display] = try container.decode(Int.self, forKey: key)
        }
        return map
    }

    struct DisplayIDKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ display: DisplayID) { stringValue = display.rawValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
