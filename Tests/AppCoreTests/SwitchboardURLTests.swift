import AppCore
import Foundation
import SwitchboardCore
import Testing

@Suite("SwitchboardURL")
struct SwitchboardURLTests {
    private func parse(_ text: String) throws -> (id: String, parameters: [String: JSONValue]) {
        let url = try #require(URL(string: text))
        return try SwitchboardURL.parse(url)
    }

    private func error(for text: String) throws -> SwitchboardURLError {
        let url = try #require(URL(string: text))
        do {
            _ = try SwitchboardURL.parse(url)
        } catch let error as SwitchboardURLError {
            return error
        }
        throw Failure("\(text) parsed but should not have")
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    @Test("a macro id")
    func macroID() throws {
        let request = try parse("switchboard://run/solo")
        #expect(request.id == "solo")
        #expect(request.parameters.isEmpty)
    }

    @Test("a macro id with dots, dashes and underscores")
    func richID() throws {
        #expect(try parse("switchboard://run/guest-room_2.v1").id == "guest-room_2.v1")
    }

    @Test("an action id with a parameter: an integer parameter arrives as an integer")
    func actionWithParameter() throws {
        let request = try parse("switchboard://run/usb.select?port=2")
        #expect(request.id == "usb.select")
        #expect(request.parameters == ["port": .int(2)])
    }

    @Test("an action with several parameters keeps choices as text and numbers as integers")
    func actionWithSeveralParameters() throws {
        let request = try parse("switchboard://run/hdmi.select?display=lg4k&input=2")
        #expect(request.parameters == ["display": .string("lg4k"), "input": .int(2)])
    }

    @Test("a value that is not a number stays text, for the runner to reject")
    func nonNumericValue() throws {
        let request = try parse("switchboard://run/usb.select?port=abc")
        #expect(request.parameters == ["port": .string("abc")])
    }

    @Test("percent-encoded text parameters are decoded")
    func encodedText() throws {
        let request = try parse("switchboard://run/notify?text=Guest%20mode%20on")
        #expect(request.parameters == ["text": .string("Guest mode on")])
    }

    @Test("a query on a macro id is kept as text (the runner ignores it)")
    func macroQuery() throws {
        let request = try parse("switchboard://run/guest?port=2")
        #expect(request.id == "guest")
        #expect(request.parameters == ["port": .string("2")])
    }

    @Test("the scheme and host are case-insensitive, a trailing slash is forgiven")
    func tolerantSpelling() throws {
        #expect(try parse("Switchboard://RUN/solo/").id == "solo")
    }

    @Test("another host is refused")
    func badHost() throws {
        #expect(try error(for: "switchboard://state/solo") == .unsupportedHost("state"))
        #expect(try error(for: "switchboard:///solo") == .unsupportedHost(nil))
    }

    @Test("another scheme is refused")
    func badScheme() throws {
        #expect(try error(for: "https://run/solo") == .wrongScheme("https"))
    }

    @Test("a missing id and a path with more than one component are refused")
    func badPath() throws {
        #expect(try error(for: "switchboard://run") == .missingID)
        #expect(try error(for: "switchboard://run/") == .missingID)
        #expect(try error(for: "switchboard://run/guest/extra") == .unexpectedPath("/guest/extra"))
    }

    @Test("an id with characters a macro id cannot have is refused")
    func badID() throws {
        #expect(try error(for: "switchboard://run/gu%20est") == .invalidID("gu est"))
        #expect(try error(for: "switchboard://run/-leading") == .invalidID("-leading"))
    }

    @Test("a parameter without a name, without a value, or given twice is refused")
    func badParameter() throws {
        #expect(try error(for: "switchboard://run/usb.select?=2") == .badParameter("a parameter has no name"))
        #expect(try error(for: "switchboard://run/usb.select?port") == .badParameter("\"port\" has no value (write port=...)"))
        #expect(try error(for: "switchboard://run/usb.select?port=1&port=2") == .badParameter("\"port\" is given more than once"))
    }

    @Test("every error says what to do")
    func messages() throws {
        #expect(SwitchboardURLError.unsupportedHost("state").description.contains("switchboard://run/{id}"))
        #expect(SwitchboardURLError.missingID.description.contains("switchboard://run/{id}"))
        #expect(SwitchboardURLError.badParameter("x").description.hasPrefix("bad parameter"))
    }
}
