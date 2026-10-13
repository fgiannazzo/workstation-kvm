import Foundation
import Observation
import SwitchboardCore

/// The one observable model (`docs/BRIEF.md`, section 4): what the monitor and the controller last
/// reported, plus the app's log. The menu bar app binds to it, `GET /state` serves it, and
/// `changes` feeds `GET /events`.
///
/// It depends on `SwitchboardCore` only. The things that read the hardware (the polling
/// `StateRefresher`, the actions) live in `Actions` and push what they read in through the
/// methods below, which is why there is `applyMonitor(pbp:mainInput:reachable:)` and not an
/// `apply(DualUpReading)`.
///
/// Every state mutation sets `updatedAt` (from the injected clock) and publishes the new state to
/// every `changes` subscriber. Writing the log does neither.
@MainActor
@Observable
public final class StateStore {
    /// The log keeps this many entries; older ones fall off the front.
    public static let logCapacity = 500
    /// A subscriber that falls this far behind loses its oldest states (each one is a complete
    /// snapshot, so only the newest matters).
    public static let subscriberBuffer = 32

    public private(set) var state: SwitchboardState
    public private(set) var log: [LogEntry] = []

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<SwitchboardState>.Continuation] = [:]

    /// - Parameters:
    ///   - initial: the starting state; a fresh app has everything unknown.
    ///   - now: the clock behind `updatedAt` and the log entries' dates; tests pass their own.
    public init(initial: SwitchboardState = SwitchboardState(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.state = initial
        self.now = now
    }

    // MARK: Mutations

    /// What a video-cable read said. `pbp` and `mainInput` may be `.unknown` (a code that could not
    /// be read stably); `reachable` is whether the monitor answered at all.
    public func applyMonitor(pbp: PBPState, mainInput: MainInput, reachable: Bool) {
        mutate {
            $0.pbp = pbp
            $0.mainInput = mainInput
            $0.dualUpReachable = reachable
        }
    }

    /// A state the controller reported (a reply to a command, a poll, or an event). The controller
    /// answered, so it is reachable.
    public func apply(_ controller: ControllerState) {
        mutate {
            $0.hdmiInput = controller.hdmi
            $0.usbPort = controller.usb.port
            $0.controllerReachable = true
        }
    }

    public func setControllerReachable(_ reachable: Bool) {
        mutate { $0.controllerReachable = reachable }
    }

    public func setDualUpReachable(_ reachable: Bool) {
        mutate { $0.dualUpReachable = reachable }
    }

    /// What the display manager says about the physical displays (`displays.off` / `displays.on`).
    public func setDisplays(_ displays: DisplaysState) {
        mutate { $0.displays = displays }
    }

    /// The last failure worth showing, or nil to clear it.
    public func setLastError(_ message: String?) {
        mutate { $0.lastError = message }
    }

    /// Appends to the ring buffer. Does not touch `state`.
    public func log(_ level: LogEntry.Level, _ message: String) {
        log.append(LogEntry(date: now(), level: level, message: message))
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }

    // MARK: Changes

    /// Every state from now on, starting with the current one. Each call is an independent stream,
    /// so any number of consumers (the API's `/events` connections, the UI) can listen. The stream
    /// ends when the consumer stops iterating.
    public var changes: AsyncStream<SwitchboardState> {
        let (stream, continuation) = AsyncStream<SwitchboardState>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.subscriberBuffer)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeSubscriber(id) }
        }
        return stream
    }

    /// How many `changes` streams are open. A test hook, like `MockESP32.eventSubscriberCount`.
    public var subscriberCount: Int { subscribers.count }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func mutate(_ change: (inout SwitchboardState) -> Void) {
        var next = state
        change(&next)
        next.updatedAt = now()
        state = next
        for continuation in subscribers.values {
            continuation.yield(next)
        }
    }
}
