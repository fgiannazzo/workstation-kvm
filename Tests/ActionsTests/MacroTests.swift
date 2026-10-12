import Actions
import Foundation
import SwitchboardCore
import Testing

/// The `GET /macros` body, copied from docs/API.md.
let apiMacrosJSON = """
{ "macros": [
  { "id": "guest", "name": "Guest",
    "steps": [ { "action": "monitor.pbp.on" }, { "action": "usb.select", "port": 2 } ],
    "verify": { "pbp": "on", "usbPort": 2 } },
  { "id": "solo", "name": "Solo",
    "steps": [ { "action": "usb.select", "port": 1 }, { "action": "monitor.pbp.off" } ],
    "verify": { "pbp": "off", "usbPort": 1 } }
] }
"""

/// The example macro from docs/DESIGN.md, "Actions": every kind of parameter.
let designMacroJSON = """
{ "id": "guest", "name": "Guest", "steps": [
    { "action": "monitor.pbp.on" },
    { "action": "usb.select", "port": 2 },
    { "action": "hdmi.select", "display": "lg4k", "input": 2 },
    { "action": "delay", "ms": 500 },
    { "action": "notify", "text": "Guest mode" } ],
  "verify": { "pbp": "on", "usbPort": 2 } }
"""

@Suite("Macro model")
struct MacroTests {
    @Test("the GET /macros body in docs/API.md decodes and re-encodes equal")
    func apiRoundTrip() throws {
        let file = try JSONDecoder().decode(MacroFile.self, from: Data(apiMacrosJSON.utf8))
        #expect(file.macros.map(\.id) == ["guest", "solo"])
        #expect(try jsonTree(file) == (try jsonTree(apiMacrosJSON)))
    }

    @Test("the shipped default macros are exactly the API.md ones")
    func defaultsMatchAPIDoc() throws {
        #expect(try jsonTree(MacroFile(macros: MacroStore.defaultMacros)) == (try jsonTree(apiMacrosJSON)))
    }

    @Test("the DESIGN.md example macro round-trips with every parameter as a sibling key")
    func designExample() throws {
        let macro = try JSONDecoder().decode(Macro.self, from: Data(designMacroJSON.utf8))
        #expect(macro.steps.map(\.action) == [.monitorPBPOn, .usbSelect, .hdmiSelect, .delay, .notify])
        #expect(macro.steps[1].parameters == ["port": 2])
        #expect(macro.steps[2].parameters == ["display": "lg4k", "input": 2])
        #expect(macro.steps[3].parameters == ["ms": 500])
        #expect(macro.steps[4].parameters == ["text": "Guest mode"])
        #expect(macro.verify == MacroVerify(pbp: .on, usbPort: 2))
        #expect(try jsonTree(macro) == (try jsonTree(designMacroJSON)))
    }

    @Test("a step keeps its parameters as sibling keys of action")
    func stepShape() throws {
        let step = MacroStep(action: .usbSelect, parameters: ["port": 2])
        #expect(try jsonTree(step) == ["action": "usb.select", "port": 2])
        let decoded = try JSONDecoder().decode(MacroStep.self, from: Data(#"{"port": 2, "action": "usb.select"}"#.utf8))
        #expect(decoded == step)
        #expect(MacroStep(action: .monitorRead).parameters.isEmpty)
        #expect(try jsonTree(MacroStep(action: .monitorRead)) == ["action": "monitor.read"])
    }

    @Test("parameters of any JSON type survive")
    func parameterTypes() throws {
        let json = #"{"action": "notify", "text": "hi", "n": 3, "x": 1.5, "on": true, "none": null, "list": [1], "obj": {"a": 1}}"#
        let step = try JSONDecoder().decode(MacroStep.self, from: Data(json.utf8))
        #expect(try jsonTree(step) == (try jsonTree(json)))
    }

    @Test("a step without an action, or with an unknown one, does not decode")
    func badSteps() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroStep.self, from: Data(#"{"port": 2}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroStep.self, from: Data(#"{"action": "pbp.explode"}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroStep.self, from: Data(#"{"action": 7}"#.utf8)) }
    }

    @Test("a parameter called action cannot be encoded")
    func reservedParameter() {
        let step = MacroStep(action: .notify, parameters: ["action": "x"])
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(step) }
    }

    @Test("a macro without verify encodes without the key")
    func noVerify() throws {
        let macro = Macro(id: "m", name: "M", steps: [MacroStep(action: .monitorRead)])
        #expect(try jsonTree(macro)["verify"] == nil)
        let decoded = try JSONDecoder().decode(Macro.self, from: Data(#"{"id":"m","name":"M","steps":[{"action":"monitor.read"}]}"#.utf8))
        #expect(decoded == macro)
    }

    @Test("verify encodes only the fields that are set, and hdmiInput as an object")
    func verifyShape() throws {
        #expect(try jsonTree(MacroVerify(pbp: .off)) == ["pbp": "off"])
        let verify = MacroVerify(pbp: .on, mainInput: .hdmi1, usbPort: 3, hdmiInput: [.lg4k: 2, .dualup: 1])
        #expect(try jsonTree(verify) == [
            "pbp": "on", "mainInput": "hdmi1", "usbPort": 3, "hdmiInput": ["dualup": 1, "lg4k": 2],
        ])
        #expect(try JSONDecoder().decode(MacroVerify.self, from: JSONEncoder().encode(verify)) == verify)
    }

    @Test("verify rejects a key it does not know and a display that does not exist")
    func verifyStrict() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroVerify.self, from: Data(#"{"pbb": "on"}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroVerify.self, from: Data(#"{"hdmiInput": {"tv": 1}}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MacroVerify.self, from: Data(#"{"pbp": "maybe"}"#.utf8)) }
    }

    @Test("an empty verify is empty; anything set is not")
    func emptiness() {
        #expect(MacroVerify().isEmpty)
        #expect(MacroVerify(hdmiInput: [:]).isEmpty)
        #expect(!MacroVerify(usbPort: 1).isEmpty)
    }

    @Test("mismatches lists every field that differs, and nothing when the state satisfies the verify")
    func mismatches() {
        let state = SwitchboardState(
            pbp: .off, mainInput: .hdmi1, usbPort: 1, hdmiInput: [.dualup: 1, .lg4k: 1],
            controllerReachable: true, dualUpReachable: true
        )
        #expect(MacroVerify(pbp: .off, mainInput: .hdmi1, usbPort: 1, hdmiInput: [.lg4k: 1]).mismatches(in: state).isEmpty)
        #expect(MacroVerify().mismatches(in: state).isEmpty)

        #expect(MacroVerify(pbp: .on).mismatches(in: state) == ["pbp: expected on, got off"])
        #expect(MacroVerify(usbPort: 2).mismatches(in: state) == ["usbPort: expected 2, got 1"])
        #expect(MacroVerify(mainInput: .hdmi2).mismatches(in: state) == ["mainInput: expected hdmi2, got hdmi1"])
        #expect(MacroVerify(hdmiInput: [.lg4k: 2, .samsung: 1]).mismatches(in: state) == [
            "hdmiInput.lg4k: expected 2, got 1", "hdmiInput.samsung: expected 1, got unknown",
        ])
        #expect(MacroVerify(pbp: .on, usbPort: 2).mismatches(in: state) == ["pbp: expected on, got off", "usbPort: expected 2, got 1"])
    }

    @Test("an unknown state never satisfies a verify")
    func unknownIsNotAMatch() {
        let state = SwitchboardState()
        #expect(MacroVerify(pbp: .on).mismatches(in: state) == ["pbp: expected on, got unknown"])
        #expect(MacroVerify(usbPort: 2).mismatches(in: state) == ["usbPort: expected 2, got unknown"])
    }

    @Test("summaries read like the macro")
    func summaries() {
        #expect(MacroStep(action: .monitorPBPOn).summary == "monitor.pbp.on")
        #expect(MacroStep(action: .usbSelect, parameters: ["port": 2]).summary == "usb.select port=2")
        #expect(MacroStep(action: .hdmiSelect, parameters: ["input": 2, "display": "lg4k"]).summary == "hdmi.select display=lg4k input=2")
        #expect(MacroVerify(pbp: .on, usbPort: 2).summary == "pbp=on usbPort=2")
    }
}
