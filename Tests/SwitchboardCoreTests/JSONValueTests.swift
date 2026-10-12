import Foundation
import SwitchboardCore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @Test("every JSON type decodes to its case")
    func decodesEachCase() throws {
        #expect(try decode(#""text""#) == .string("text"))
        #expect(try decode("2") == .int(2))
        #expect(try decode("-7") == .int(-7))
        #expect(try decode("2.5") == .double(2.5))
        #expect(try decode("true") == .bool(true))
        #expect(try decode("false") == .bool(false))
        #expect(try decode("null") == .null)
        #expect(try decode("[1, \"a\", null]") == .array([.int(1), .string("a"), .null]))
        #expect(try decode(#"{"port": 2}"#) == .object(["port": .int(2)]))
    }

    @Test("numbers are not confused with booleans or strings")
    func numbersAreNumbers() throws {
        #expect(try decode("1") == .int(1))
        #expect(try decode("0") == .int(0))
        #expect(try decode(#""1""#) == .string("1"))
        #expect(try decode("true") != .int(1))
    }

    @Test("an arbitrary document round-trips")
    func roundTrip() throws {
        let json = """
        { "a": [1, 2.5, "three", true, false, null, [], {}],
          "b": { "c": { "d": [ { "e": "f" } ] }, "g": -4 },
          "h": "quote \\" backslash \\\\ unicode \\u00e9 \\ud83d\\ude00",
          "i": 9007199254740993 }
        """
        let value = try decode(json)
        let again = try JSONDecoder().decode(JSONValue.self, from: try encode(value))
        #expect(again == value)
        // The big integer stays an integer instead of rounding through a double.
        #expect(value["i"] == .int(9_007_199_254_740_993))
    }

    @Test("the encoded form is plain JSON a stock decoder reads")
    func encodesPlainJSON() throws {
        let value: JSONValue = ["action": "usb.select", "port": 2, "ratio": 0.5, "on": true, "none": nil, "list": [1, 2]]
        let object = try #require(try JSONSerialization.jsonObject(with: try encode(value)) as? NSDictionary)
        #expect(object == [
            "action": "usb.select", "port": 2, "ratio": 0.5, "on": true, "none": NSNull(), "list": [1, 2],
        ] as NSDictionary)
    }

    @Test("the literal conveniences build the matching cases")
    func literals() {
        let string: JSONValue = "x"
        let int: JSONValue = 3
        let double: JSONValue = 1.5
        let bool: JSONValue = true
        let null: JSONValue = nil
        let array: JSONValue = [1, "a"]
        let object: JSONValue = ["k": 1]
        #expect(string == .string("x"))
        #expect(int == .int(3))
        #expect(double == .double(1.5))
        #expect(bool == .bool(true))
        #expect(null == .null)
        #expect(array == .array([.int(1), .string("a")]))
        #expect(object == .object(["k": .int(1)]))
    }

    @Test("accessors return the payload for their case and nil for any other")
    func accessors() {
        #expect(JSONValue.string("a").stringValue == "a")
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.int(4).intValue == 4)
        #expect(JSONValue.string("4").intValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        #expect(JSONValue.int(2).doubleValue == 2.0)
        #expect(JSONValue.double(2.5).doubleValue == 2.5)
        #expect(JSONValue.bool(false).boolValue == false)
        #expect(JSONValue.int(0).boolValue == nil)
        #expect(JSONValue.array([.null]).arrayValue == [.null])
        #expect(JSONValue.object(["a": .null]).objectValue == ["a": .null])
        #expect(JSONValue.null.isNull)
        #expect(!JSONValue.int(0).isNull)
    }

    @Test("a whole double reads as an integer, a fractional one does not")
    func integralDoubles() {
        #expect(JSONValue.double(2.0).intValue == 2)
        #expect(JSONValue.double(2.5).intValue == nil)
        #expect(JSONValue.double(.infinity).intValue == nil)
        #expect(JSONValue.double(.nan).intValue == nil)
        #expect(JSONValue.double(1e300).intValue == nil)
    }

    @Test("subscripts read objects and arrays, and are nil elsewhere")
    func subscripts() {
        let value: JSONValue = ["steps": [["port": 2]]]
        #expect(value["steps"]?[0]?["port"] == .int(2))
        #expect(value["missing"] == nil)
        #expect(value["steps"]?[1] == nil)
        #expect(JSONValue.int(1)["a"] == nil)
        #expect(JSONValue.int(1)[0] == nil)
    }

    @Test("description is compact JSON with sorted keys")
    func description() {
        #expect(JSONValue.string("a").description == "\"a\"")
        #expect(JSONValue.int(5).description == "5")
        #expect(JSONValue.null.description == "null")
        #expect(JSONValue.object(["b": 1, "a": [true]]).description == #"{"a":[true],"b":1}"#)
    }

    @Test("not JSON throws")
    func invalid() {
        #expect(throws: (any Error).self) { try decode("{") }
    }
}
