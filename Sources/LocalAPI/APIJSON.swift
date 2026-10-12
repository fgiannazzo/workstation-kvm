import Foundation

/// The JSON dialect of the local API (`docs/API.md`, "Encoding"): UTF-8, one line, and dates as
/// ISO 8601 with milliseconds and a `Z`, for example `2026-10-11T20:15:03.120Z`.
///
/// `JSONEncoder`'s own `.iso8601` strategy has no fractional seconds, and `ISO8601DateFormatter`
/// truncates a binary fraction (`...03.12` can print as `.119`), so the date is formatted here:
/// rounded to the millisecond, then split into a civil date and a time of day. Keys are sorted so
/// the same value always produces the same bytes.
public enum APIJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(APIJSON.string(from: date))
        }
        return encoder
    }

    /// Accepts what `makeEncoder` writes, and also a date without fractional seconds or with a
    /// numeric UTC offset, since clients and hand-written files are not always this strict.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = APIJSON.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "\"\(text)\" is not an ISO 8601 date such as 2026-10-11T20:15:03.120Z"
                )
            }
            return date
        }
        return decoder
    }

    /// What a state that has never been updated carries as `updatedAt`: `Date.distantPast`, the
    /// first instant of year 1. Foundation counts that instant on the Julian calendar, which
    /// proleptic Gregorian arithmetic would print as 0000-12-30, so it has a fixed spelling both
    /// ways and survives a round trip exactly.
    public static let neverUpdated = "0001-01-01T00:00:00.000Z"

    /// `2026-10-11T20:15:03.120Z`: UTC, exactly three fractional digits.
    public static func string(from date: Date) -> String {
        if date <= Date.distantPast { return neverUpdated }
        let seconds = date.timeIntervalSince1970
        // Clamp so a non-finite or absurd date cannot trap in the integer conversion.
        let milliseconds = Int((seconds.isFinite ? max(-1e17, min(1e17, seconds * 1000)) : 0).rounded())
        let wholeSeconds = floorDivide(milliseconds, 1000)
        let fraction = milliseconds - wholeSeconds * 1000
        let days = floorDivide(wholeSeconds, 86_400)
        let secondOfDay = wholeSeconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
            + "T" + pad(secondOfDay / 3600, 2) + ":" + pad(secondOfDay / 60 % 60, 2) + ":" + pad(secondOfDay % 60, 2)
            + "." + pad(fraction, 3) + "Z"
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM|±HHMM)`. Nil for anything else.
    public static func date(from text: String) -> Date? {
        if text == neverUpdated { return Date.distantPast }
        let bytes = Array(text.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }
        func expect(_ characters: UInt8...) -> Bool {
            guard index < bytes.count, characters.contains(bytes[index]) else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), expect(0x2D),
              let month = digits(2), expect(0x2D),
              let day = digits(2), expect(0x54, 0x74),
              let hour = digits(2), expect(0x3A),
              let minute = digits(2), expect(0x3A),
              let second = digits(2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var fraction = 0.0
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let start = index
            var numerator = 0
            var denominator = 1
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                // Nine digits are a nanosecond; anything finer cannot change a Date.
                if denominator < 1_000_000_000 {
                    numerator = numerator * 10 + Int(bytes[index] - 0x30)
                    denominator *= 10
                }
                index += 1
            }
            guard index > start else { return nil }
            fraction = Double(numerator) / Double(denominator)
        }

        var offsetSeconds = 0
        if expect(0x5A, 0x7A) {
            // UTC
        } else if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            let sign = bytes[index] == 0x2D ? -1 : 1
            index += 1
            guard let offsetHours = digits(2) else { return nil }
            _ = expect(0x3A)
            guard let offsetMinutes = digits(2), offsetHours < 24, offsetMinutes < 60 else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        } else {
            return nil
        }
        guard index == bytes.count else { return nil }

        let wholeSeconds = days(fromCivil: year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(wholeSeconds) + fraction)
    }

    // MARK: Calendar arithmetic (proleptic Gregorian, days since 1970-01-01)

    private static func floorDivide(_ numerator: Int, _ denominator: Int) -> Int {
        let quotient = numerator / denominator
        return numerator % denominator < 0 ? quotient - 1 : quotient
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// Howard Hinnant's `civil_from_days`.
    private static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDivide(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// Howard Hinnant's `days_from_civil`.
    private static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = floorDivide(y, 400)
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
