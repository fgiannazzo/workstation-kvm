import Foundation

/// What a command-line tool printed and how it exited.
public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// The process was killed because it ran past its timeout.
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs an executable with arguments and waits for it. Injected so tests never start a process.
public typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: Duration) async throws -> CommandOutput

public enum ProcessRunner {
    /// Starts `executable` directly (no shell, so no quoting), reads stdout and stderr to the end,
    /// and terminates it when it runs longer than `timeout`. The blocking waits run on a global
    /// dispatch queue, not on the Swift concurrency pool.
    public static let run: CommandRunner = { executable, arguments, timeout in
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let running = UncheckedBox(process)
                let timedOut = LockedFlag()
                let killer = DispatchWorkItem {
                    if running.value.isRunning {
                        timedOut.set()
                        running.value.terminate()
                    }
                }
                let (seconds, attoseconds) = timeout.components
                let interval = Double(seconds) + Double(attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: killer)

                // Drain stderr on another thread so neither pipe can fill up and stall the tool.
                let errorData = LockedData()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorData.set(stderr.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()

                continuation.resume(returning: CommandOutput(
                    status: process.terminationStatus,
                    stdout: String(decoding: outputData, as: UTF8.self),
                    stderr: String(decoding: errorData.get(), as: UTF8.self),
                    timedOut: timedOut.get()
                ))
            }
        }
    }
}

/// Hands a non-Sendable value to the timeout work item, which only reads it on a queue while the
/// creating thread is blocked waiting.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    func get() -> Bool { lock.withLock { flag } }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.withLock { data = new } }
    func get() -> Data { lock.withLock { data } }
}
