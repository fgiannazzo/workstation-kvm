import DDCKit
import Devices
import Foundation
import SwitchboardCore

/// Turns the physical displays off and on (`displays.off`, `displays.on`) through a
/// `DisplayConnector`, and reads them back. Like the monitor writes, a change counts only once a
/// read shows it: each display is read until it reports the wanted state, for up to `attempts`
/// reads `settle` apart.
///
/// Which displays: the ones named in `Settings.displaysToTurnOff` (name, EDID serial or UUID), or
/// every physical display the connector lists when that is empty. A display this switch turned
/// off is remembered for the life of the process, so it is still counted (as off) and turned back
/// on if the connector stops listing it while it is disconnected.
public actor DisplaySwitch {
    public nonisolated let connector: any DisplayConnector
    public nonisolated let selectors: [String]
    private let sleep: Sleeper
    private let settle: Duration
    private let attempts: Int
    private var turnedOff: [String: ManagedDisplay] = [:]

    public init(
        connector: any DisplayConnector,
        selectors: [String] = [],
        sleep: @escaping Sleeper = Timing.realSleep,
        settle: Duration = .milliseconds(500),
        attempts: Int = 10
    ) {
        self.connector = connector
        self.selectors = selectors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.sleep = sleep
        self.settle = settle
        self.attempts = max(1, attempts)
    }

    /// The displays as one value: `on`, `off`, `mixed`, or `unknown` when the connector cannot be
    /// asked or knows none of them. Reads only.
    public func read() async -> DisplaysState {
        guard let targets = try? await targets() else { return .unknown }
        var states: [Bool] = []
        for display in targets {
            switch await connection(of: display) {
            case true?:
                turnedOff[display.uuid] = nil
                states.append(true)
            case false?:
                states.append(false)
            case nil:
                if turnedOff[display.uuid] != nil { states.append(false) }
            }
        }
        return .aggregate(states)
    }

    /// Disconnects every target and waits for each to read back disconnected (or to drop out of
    /// the connector's list, which is how a manager may show it). Returns their names.
    public func turnOff() async throws -> [String] {
        let targets = try await requireTargets()
        var problems: [String] = []
        var requested: [ManagedDisplay] = []
        for display in targets {
            if await connection(of: display) == false {
                turnedOff[display.uuid] = display
                requested.append(display)
                continue
            }
            do {
                try await connector.setConnected(display, false)
                turnedOff[display.uuid] = display
                requested.append(display)
            } catch is CancellationError {
                throw ActionError.cancelled
            } catch {
                problems.append("\(display.name): \(error)")
            }
        }
        problems += try await verify(requested, connected: false).map(\.line)
        if !problems.isEmpty { throw ActionError.verifyFailed(problems) }
        return targets.map(\.name)
    }

    /// Connects the targets again and waits for each to read back connected. With no
    /// `displaysToTurnOff` it asks the connector to connect every display, listed or not.
    public func turnOn() async throws -> [String] {
        let known = try await requireTargets()
        var problems: [String] = []
        if selectors.isEmpty {
            do {
                try await connector.connectAll()
            } catch is CancellationError {
                throw ActionError.cancelled
            } catch {
                throw ActionError.displaysUnavailable("\(error)")
            }
        } else {
            for display in known where await connection(of: display) != true {
                do {
                    try await connector.setConnected(display, true)
                } catch is CancellationError {
                    throw ActionError.cancelled
                } catch {
                    problems.append("\(display.name): \(error)")
                }
            }
        }
        // A reconnected display may only now be listed again.
        let targets = (try? await targets()) ?? known
        let missing = try await verify(targets, connected: true)
        for display in targets where !missing.contains(where: { $0.display == display }) {
            turnedOff[display.uuid] = nil
        }
        problems += missing.map(\.line)
        if !problems.isEmpty { throw ActionError.verifyFailed(problems) }
        return targets.map(\.name)
    }

    // MARK: Helpers

    /// Listed displays plus the ones this switch turned off, narrowed to the selectors.
    private func targets() async throws -> [ManagedDisplay] {
        var all = try await connector.displays()
        for display in turnedOff.values.sorted(by: { $0.name < $1.name }) where !all.contains(where: { $0.uuid == display.uuid }) {
            all.append(display)
        }
        if selectors.isEmpty { return all }
        return all.filter { display in selectors.contains { display.matches($0) } }
    }

    private func requireTargets() async throws -> [ManagedDisplay] {
        let targets: [ManagedDisplay]
        do {
            targets = try await self.targets()
        } catch is CancellationError {
            throw ActionError.cancelled
        } catch {
            throw ActionError.displaysUnavailable("\(error)")
        }
        guard !targets.isEmpty else {
            let which = selectors.isEmpty ? "no physical displays are listed" : "no display matches displaysToTurnOff (\(selectors.joined(separator: ", ")))"
            throw ActionError.displaysUnavailable("nothing to switch: \(which)")
        }
        return targets
    }

    /// nil when the connector does not know the display or could not be asked.
    private func connection(of display: ManagedDisplay) async -> Bool? {
        (try? await connector.isConnected(display)) ?? nil
    }

    /// Reads each display until it shows `connected` (a display that is no longer known counts as
    /// disconnected), up to `attempts` reads. Returns the displays that never did, with a line each.
    private func verify(_ displays: [ManagedDisplay], connected wanted: Bool) async throws -> [(display: ManagedDisplay, line: String)] {
        var pending = displays
        for attempt in 1...attempts {
            var still: [ManagedDisplay] = []
            for display in pending {
                let now = await connection(of: display)
                let done = wanted ? now == true : now != true
                if !done { still.append(display) }
            }
            pending = still
            if pending.isEmpty || attempt == attempts { break }
            await sleep(settle)
            if Task.isCancelled { throw ActionError.cancelled }
        }
        var mismatches: [(display: ManagedDisplay, line: String)] = []
        for display in pending {
            let now = await connection(of: display)
            let shown = now.map { $0 ? "connected" : "disconnected" } ?? "unknown to BetterDisplay"
            mismatches.append((display, "\(display.name): \(shown), expected \(wanted ? "connected" : "disconnected")"))
        }
        return mismatches
    }
}
