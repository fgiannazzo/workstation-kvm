import Foundation
import SwitchboardCore

/// An in-memory `DisplayConnector` for tests, with the behaviours worth testing against: a change
/// that shows up only after a few reads, a manager that stops listing disconnected displays, one
/// that refuses to disconnect the last connected display (BetterDisplay tries not to leave the Mac
/// without any), and displays whose requests fail.
public actor FakeDisplayConnector: DisplayConnector {
    public struct Behaviour: Sendable {
        /// Reads of `isConnected` that still return the old value after a `setConnected`.
        public var settleReads = 0
        /// `displays()` leaves out disconnected displays.
        public var unlistsDisconnected = false
        /// Refuses to disconnect the last display that is still connected.
        public var refusesLastDisconnect = false
        /// `setConnected` throws for these UUIDs.
        public var failingUUIDs: Set<String> = []
        /// `setConnected` is accepted but nothing changes for these UUIDs.
        public var ignoredUUIDs: Set<String> = []

        public init() {}
    }

    public private(set) var all: [ManagedDisplay]
    public private(set) var connected: [String: Bool]
    /// Every request, in order, for example `set <uuid> off` or `connectAll`.
    public private(set) var requests: [String] = []
    public var behaviour: Behaviour
    private var pendingReads: [String: Int] = [:]

    public init(displays: [ManagedDisplay], behaviour: Behaviour = Behaviour()) {
        self.all = displays
        self.connected = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, true) })
        self.behaviour = behaviour
    }

    public func setBehaviour(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    public func displays() async throws -> [ManagedDisplay] {
        behaviour.unlistsDisconnected ? all.filter { connected[$0.uuid] == true } : all
    }

    public func isConnected(_ display: ManagedDisplay) async throws -> Bool? {
        requests.append("get \(display.uuid)")
        guard let value = connected[display.uuid] else { return nil }
        if let left = pendingReads[display.uuid], left > 0 {
            pendingReads[display.uuid] = left - 1
            return !value
        }
        return value
    }

    public func setConnected(_ display: ManagedDisplay, _ wanted: Bool) async throws {
        requests.append("set \(display.uuid) \(wanted ? "on" : "off")")
        if behaviour.failingUUIDs.contains(display.uuid) {
            throw DisplayConnectorError.failed(command: "set -UUID=\(display.uuid)", status: 1, output: "Failed.")
        }
        guard connected[display.uuid] != nil else {
            throw DisplayConnectorError.failed(command: "set -UUID=\(display.uuid)", status: 1, output: "Failed.")
        }
        if !wanted, behaviour.refusesLastDisconnect, connected.values.filter({ $0 }).count <= 1, connected[display.uuid] == true {
            throw DisplayConnectorError.failed(command: "set -UUID=\(display.uuid)", status: 1, output: "Failed.")
        }
        if behaviour.ignoredUUIDs.contains(display.uuid) { return }
        change(display.uuid, to: wanted)
    }

    public func connectAll() async throws {
        requests.append("connectAll")
        for uuid in connected.keys where !behaviour.ignoredUUIDs.contains(uuid) {
            change(uuid, to: true)
        }
    }

    private func change(_ uuid: String, to value: Bool) {
        if connected[uuid] != value, behaviour.settleReads > 0 { pendingReads[uuid] = behaviour.settleReads }
        connected[uuid] = value
    }
}
