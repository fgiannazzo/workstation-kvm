import Foundation

/// Bridges a one-shot callback API to async/await.
///
/// `register` is called synchronously and must arrange for the completion
/// closure it receives to be invoked exactly once; extra invocations are
/// ignored. If the awaiting task is cancelled before the callback fires,
/// `onCancel` runs and the call throws `CancellationError`. A callback that
/// arrives afterwards is dropped.
func awaitCallback<T: Sendable>(
    onCancel: @escaping @Sendable () -> Void = {},
    _ register: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void
) async throws -> T {
    let state = CallbackState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            state.attach(continuation)
            register { result in state.resume(with: result) }
        }
    } onCancel: {
        onCancel()
        state.resume(with: .failure(CancellationError()))
    }
}

private final class CallbackState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var earlyResult: Result<T, any Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let result = earlyResult {
            earlyResult = nil
            finished = true
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<T, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            finished = true
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if earlyResult == nil {
            earlyResult = result
        }
        lock.unlock()
    }
}
