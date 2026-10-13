import DDCKit
import Devices
import ESP32Kit
import Foundation
import StateStore
import SwitchboardCore

/// Parameters that passed `ActionRegistry.validate`. Reading one cannot fail afterwards, which
/// keeps the action bodies free of unwrapping.
public struct ActionArguments: Sendable, Equatable {
    fileprivate var values: [String: JSONValue] = [:]

    public func int(_ name: String) -> Int { values[name]?.intValue ?? 0 }
    public func string(_ name: String) -> String { values[name]?.stringValue ?? "" }
    public func display(_ name: String = "display") -> DisplayID { DisplayID(rawValue: string(name)) ?? .dualup }
}

/// The ten actions: their descriptors (for `GET /actions` and the macro editor), the validation
/// of their parameters, and what each one does.
///
/// The monitor writes are exactly `LGDualUp.perform(.pbpOn)` and `perform(.pbpOff)`, and an
/// unverified write is a failure (`ActionError.unverified`). Nothing else here writes to hardware;
/// the `hdmi.*` and `usb.*` actions go to the controller through `ControllerClient`, and
/// `displays.*` change macOS's display configuration through BetterDisplay (`DisplaySwitch`),
/// which sends the monitors nothing.
public struct ActionRegistry: Sendable {
    /// In `docs/API.md` order.
    public let descriptors: [ActionDescriptor]

    public init() {
        let displays = DisplayID.allCases.map(\.rawValue)
        descriptors = [
            ActionDescriptor(id: .monitorPBPOn, title: "PBP on"),
            ActionDescriptor(id: .monitorPBPOff, title: "PBP off"),
            ActionDescriptor(id: .monitorRead, title: "Read monitor"),
            ActionDescriptor(id: .hdmiSelect, title: "HDMI input", parameters: [
                .choice("display", values: displays),
                .int("input", min: 1, max: 2),
            ]),
            ActionDescriptor(id: .hdmiResync, title: "HDMI resync (set assumed input)", parameters: [
                .choice("display", values: displays),
                .int("input", min: 1, max: 2),
            ]),
            ActionDescriptor(id: .usbSelect, title: "USB to port", parameters: [
                .int("port", min: 1, max: 4),
            ]),
            ActionDescriptor(id: .delay, title: "Wait", parameters: [
                .int("ms", min: 0, max: 60000),
            ]),
            ActionDescriptor(id: .notify, title: "Notification", parameters: [
                .string("text"),
            ]),
            ActionDescriptor(id: .displaysOff, title: "Displays off"),
            ActionDescriptor(id: .displaysOn, title: "Displays on"),
        ]
    }

    public func descriptor(for id: ActionID) -> ActionDescriptor {
        // Every case has a descriptor, built in init.
        descriptors.first { $0.id == id } ?? ActionDescriptor(id: id, title: id.rawValue)
    }

    // MARK: Validation

    /// Checks `parameters` against the action's descriptors: every declared parameter present and
    /// of the right type and range, and nothing undeclared. `null` counts as absent.
    ///
    /// - `display` is a `DisplayID`, `input` 1 to 2, `port` 1 to 4, `ms` 0 to 60000, `text` a string.
    public func validate(_ id: ActionID, parameters: [String: JSONValue]) throws -> ActionArguments {
        let descriptor = descriptor(for: id)
        var arguments = ActionArguments()

        for parameter in descriptor.parameters {
            guard let value = parameters[parameter.name], !value.isNull else {
                throw ActionError.missingParameter(parameter.name)
            }
            switch parameter.type {
            case .int:
                guard let number = value.intValue else {
                    throw ActionError.invalidParameter(parameter.name, "must be a whole number, got \(value)")
                }
                let low = parameter.min ?? Int.min
                let high = parameter.max ?? Int.max
                guard (low...high).contains(number) else {
                    throw ActionError.invalidParameter(parameter.name, "must be \(low) to \(high), got \(number)")
                }
                arguments.values[parameter.name] = .int(number)
            case .choice:
                let allowed = parameter.values ?? []
                guard let text = value.stringValue, allowed.contains(text) else {
                    throw ActionError.invalidParameter(parameter.name, "must be one of \(allowed.joined(separator: ", ")), got \(value)")
                }
                arguments.values[parameter.name] = .string(text)
            case .string:
                guard let text = value.stringValue else {
                    throw ActionError.invalidParameter(parameter.name, "must be text, got \(value)")
                }
                arguments.values[parameter.name] = .string(text)
            }
        }

        if let extra = parameters.keys.sorted().first(where: { name in !descriptor.parameters.contains { $0.name == name } }) {
            throw ActionError.invalidParameter(extra, "\(id.rawValue) has no such parameter")
        }
        return arguments
    }

    /// Whether `context` has what the action needs: the controller for `hdmi.*` and `usb.*`, the
    /// monitor for `monitor.*`. Cheap and side-effect free, so a macro can check all its steps
    /// before it moves any hardware.
    public func checkAvailability(of id: ActionID, in context: ActionContext) throws {
        switch id {
        case .monitorPBPOn, .monitorPBPOff, .monitorRead:
            if context.dualUp == nil { throw ActionError.monitorNotConfigured }
        case .hdmiSelect, .hdmiResync, .usbSelect:
            if context.controller == nil { throw ActionError.controllerNotConfigured }
        case .displaysOff, .displaysOn:
            if context.displays == nil { throw ActionError.displaysNotConfigured }
        case .delay, .notify:
            break
        }
    }

    // MARK: Running

    /// Validates, runs one action and returns the human message used in `run` events
    /// (`monitor.pbp.on: verified 0xD7 = 0`). Throws `ActionError` only; a cancelled task surfaces
    /// as `ActionError.cancelled`.
    public func run(_ id: ActionID, parameters: [String: JSONValue], context: ActionContext) async throws -> String {
        let arguments = try validate(id, parameters: parameters)
        try checkAvailability(of: id, in: context)

        switch id {
        case .monitorPBPOn:
            return try await writePBP(.pbpOn, id: id, context: context)
        case .monitorPBPOff:
            return try await writePBP(.pbpOff, id: id, context: context)
        case .monitorRead:
            return try await readMonitor(id: id, context: context)

        case .hdmiSelect:
            let display = arguments.display()
            let input = arguments.int("input")
            let state = try await callController(context) { try await $0.selectHDMI(display, input: input) }
            try Self.require(state.hdmi[display] == input, "hdmiInput.\(display.rawValue): expected \(input), got \(Self.text(state.hdmi[display]))")
            return "\(id.rawValue): \(display.rawValue) input \(input)"
        case .hdmiResync:
            let display = arguments.display()
            let input = arguments.int("input")
            let state = try await callController(context) { try await $0.resyncHDMI(display, input: input) }
            try Self.require(state.hdmi[display] == input, "hdmiInput.\(display.rawValue): expected \(input), got \(Self.text(state.hdmi[display]))")
            return "\(id.rawValue): \(display.rawValue) assumed input \(input)"
        case .usbSelect:
            let port = arguments.int("port")
            let state = try await callController(context) { try await $0.selectUSB(port: port) }
            try Self.require(state.usb.port == port, "usbPort: expected \(port), got \(state.usb.port)")
            return "\(id.rawValue): port \(port)"

        case .delay:
            let milliseconds = arguments.int("ms")
            await context.sleep(.milliseconds(milliseconds))
            if Task.isCancelled { throw ActionError.cancelled }
            return "\(id.rawValue): \(milliseconds) ms"
        case .notify:
            let text = arguments.string("text")
            await context.notify(text)
            return "\(id.rawValue): \(text)"

        case .displaysOff:
            let names = try await switchDisplays(on: false, context: context)
            return "\(id.rawValue): disconnected \(names.joined(separator: ", "))"
        case .displaysOn:
            let names = try await switchDisplays(on: true, context: context)
            return "\(id.rawValue): connected \(names.joined(separator: ", "))"
        }
    }

    // MARK: Displays

    /// Turns the displays off or on and puts what reads back into the store, whether or not the
    /// switch was verified.
    private func switchDisplays(on: Bool, context: ActionContext) async throws -> [String] {
        guard let displays = context.displays else { throw ActionError.displaysNotConfigured }
        do {
            let names = on ? try await displays.turnOn() : try await displays.turnOff()
            await context.store.setDisplays(await displays.read())
            return names
        } catch {
            await context.store.setDisplays(await displays.read())
            if error is CancellationError { throw ActionError.cancelled }
            throw error
        }
    }

    // MARK: Monitor

    private func writePBP(_ command: LGDualUpCommand, id: ActionID, context: ActionContext) async throws -> String {
        guard let dualUp = context.dualUp else { throw ActionError.monitorNotConfigured }
        let outcome: WriteOutcome
        do {
            outcome = try await dualUp.perform(command)
        } catch is CancellationError {
            throw ActionError.cancelled
        } catch {
            throw ActionError.monitorUnavailable("\(error)")
        }
        // The read-back is the truth, verified or not: put it in the store before judging it.
        await context.store.applyMonitor(
            pbp: outcome.reading.pbp,
            mainInput: outcome.reading.mainInput,
            reachable: !outcome.reading.raw.isEmpty
        )
        guard outcome.verified else { throw ActionError.unverified(outcome) }
        return "\(id.rawValue): verified 0x\(DDCPacket.hexString([outcome.command.code])) = \(outcome.expected)"
    }

    private func readMonitor(id: ActionID, context: ActionContext) async throws -> String {
        guard let dualUp = context.dualUp else { throw ActionError.monitorNotConfigured }
        let reading = await dualUp.readState()
        let reachable = !reading.raw.isEmpty
        await context.store.applyMonitor(pbp: reading.pbp, mainInput: reading.mainInput, reachable: reachable)
        guard reachable else {
            throw ActionError.monitorUnavailable("the monitor did not answer on the video cable (neither 0xD7 nor 0xF5 could be read)")
        }
        return "\(id.rawValue): pbp \(reading.pbp.rawValue), main input \(reading.mainInput.rawValue)"
    }

    // MARK: Controller

    /// Runs one controller command and records the state it answered with. A controller that
    /// cannot be reached is marked unreachable in the store.
    private func callController(
        _ context: ActionContext,
        _ command: (any ControllerClient) async throws -> ControllerState
    ) async throws -> ControllerState {
        guard let controller = context.controller else { throw ActionError.controllerNotConfigured }
        do {
            let state = try await command(controller)
            await context.store.apply(state)
            return state
        } catch let error as ControllerError {
            let wrapped = ActionError.controller(error)
            if wrapped.isControllerUnreachable { await context.store.setControllerReachable(false) }
            throw wrapped
        } catch is CancellationError {
            throw ActionError.cancelled
        }
    }

    /// The controller answered, but its state does not show what was asked for. The reply is
    /// already in the store; the action still fails, because success is not taken from the request.
    private static func require(_ holds: Bool, _ mismatch: @autoclosure () -> String) throws {
        if !holds { throw ActionError.verifyFailed([mismatch()]) }
    }

    private static func text(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }
}
