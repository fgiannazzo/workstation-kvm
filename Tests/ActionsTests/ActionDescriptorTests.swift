import Actions
import Foundation
import SwitchboardCore
import Testing

/// The `GET /actions` body, copied from docs/API.md.
let apiActionsJSON = """
{ "actions": [
  { "id": "monitor.pbp.on",  "title": "PBP on",  "parameters": [] },
  { "id": "monitor.pbp.off", "title": "PBP off", "parameters": [] },
  { "id": "monitor.read",    "title": "Read monitor", "parameters": [] },
  { "id": "hdmi.select", "title": "HDMI input", "parameters": [
      { "name": "display", "type": "enum", "values": ["dualup", "lg4k", "samsung"] },
      { "name": "input", "type": "int", "min": 1, "max": 2 } ] },
  { "id": "hdmi.resync", "title": "HDMI resync (set assumed input)", "parameters": [
      { "name": "display", "type": "enum", "values": ["dualup", "lg4k", "samsung"] },
      { "name": "input", "type": "int", "min": 1, "max": 2 } ] },
  { "id": "usb.select", "title": "USB to port", "parameters": [
      { "name": "port", "type": "int", "min": 1, "max": 4 } ] },
  { "id": "delay",  "title": "Wait", "parameters": [ { "name": "ms", "type": "int", "min": 0, "max": 60000 } ] },
  { "id": "notify", "title": "Notification", "parameters": [ { "name": "text", "type": "string" } ] },
  { "id": "displays.off", "title": "Displays off", "parameters": [] },
  { "id": "displays.on",  "title": "Displays on",  "parameters": [] }
] }
"""

/// Encodes with the stock encoder and reads the result back as a comparable tree.
func jsonTree(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func jsonTree(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("Action descriptors")
struct ActionDescriptorTests {
    @Test("GET /actions encodes to exactly the JSON in docs/API.md")
    func matchesAPIDoc() throws {
        let encoded = try jsonTree(ActionList(actions: ActionRegistry().descriptors))
        #expect(encoded == (try jsonTree(apiActionsJSON)))
    }

    @Test("the API.md body decodes to the registry's descriptors")
    func decodesAPIDoc() throws {
        let list = try JSONDecoder().decode(ActionList.self, from: Data(apiActionsJSON.utf8))
        #expect(list.actions == ActionRegistry().descriptors)
    }

    @Test("descriptors are in API.md order and cover every action id once")
    func order() {
        let ids = ActionRegistry().descriptors.map(\.id.rawValue)
        #expect(ids == ["monitor.pbp.on", "monitor.pbp.off", "monitor.read", "hdmi.select", "hdmi.resync", "usb.select", "delay", "notify", "displays.off", "displays.on"])
        #expect(Set(ids.compactMap(ActionID.init(rawValue:))) == Set(ActionID.allCases))
    }

    @Test("absent keys are omitted, not null")
    func omitsAbsentKeys() throws {
        let port = try jsonTree(ParameterDescriptor.int("port", min: 1, max: 4))
        #expect(port == ["name": "port", "type": "int", "min": 1, "max": 4])
        let text = try jsonTree(ParameterDescriptor.string("text"))
        #expect(text == ["name": "text", "type": "string"])
        let display = try jsonTree(ParameterDescriptor.choice("display", values: ["a", "b"]))
        #expect(display == ["name": "display", "type": "enum", "values": ["a", "b"]])
    }

    @Test("an action without parameters still encodes an empty parameters array")
    func emptyParameters() throws {
        let tree = try jsonTree(ActionDescriptor(id: .monitorRead, title: "Read monitor"))
        #expect(tree["parameters"] == [])
    }

    @Test("an unknown action id fails to decode and names the known ones")
    func unknownAction() {
        do {
            _ = try JSONDecoder().decode(ActionID.self, from: Data(#""monitor.explode""#.utf8))
            Issue.record("expected a decoding error")
        } catch let error as DecodingError {
            guard case .dataCorrupted(let context) = error else { Issue.record("wrong error \(error)"); return }
            #expect(context.debugDescription.contains("monitor.explode"))
            #expect(context.debugDescription.contains("usb.select"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("key=value text becomes the parameter types the action declares")
    func textCoercion() {
        let registry = ActionRegistry()
        let usb = registry.descriptor(for: .usbSelect)
        #expect(usb.parameters(fromText: ["port": "2"]) == ["port": .int(2)])
        #expect(usb.parameters(fromText: ["port": "x"]) == ["port": .string("x")])   // validation reports it
        #expect(usb.parameters(fromText: ["extra": "1"]) == ["extra": .string("1")])

        let hdmi = registry.descriptor(for: .hdmiSelect)
        #expect(hdmi.parameters(fromText: ["display": "lg4k", "input": "2"]) == ["display": "lg4k", "input": 2])

        // A string parameter stays a string even when it looks like a number.
        let notify = registry.descriptor(for: .notify)
        #expect(notify.parameters(fromText: ["text": "123"]) == ["text": "123"])
    }

    @Test("signature summarises the parameters for listings")
    func signature() {
        let registry = ActionRegistry()
        #expect(registry.descriptor(for: .monitorRead).signature == "")
        #expect(registry.descriptor(for: .usbSelect).signature == "port:int(1-4)")
        #expect(registry.descriptor(for: .hdmiSelect).signature == "display:dualup|lg4k|samsung input:int(1-2)")
        #expect(registry.descriptor(for: .notify).signature == "text:string")
    }
}
