import Foundation

public enum DeadlineError: Error { case expired }

private final class DeadlineState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ c: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); c.resume(with: result); return false }
        continuation = c
        lock.unlock()
        return true
    }
    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil { lock.unlock(); tasks.forEach { $0.cancel() }; return }
        self.tasks = tasks
        lock.unlock()
    }
    @discardableResult func resolve(_ value: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let c = continuation
        continuation = nil
        let pending = tasks
        tasks = []
        lock.unlock()
        c?.resume(with: value)
        pending.forEach { $0.cancel() }
        return true
    }
}

/// A timed-out or cancelled AVFoundation load must not hold the UI hostage.
/// A late result is ignored, including when the provider ignores cancellation.
public enum AsyncDeadline {
    public static func run<Value: Sendable>(seconds: Double,
                                            onCancel: @escaping @Sendable () -> Void = {},
                                            operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let state = DeadlineState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                guard state.install(c) else { return }
                let worker = Task {
                    do { try Task.checkCancellation(); state.resolve(.success(try await operation())) }
                    catch { state.resolve(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                        if state.resolve(.failure(DeadlineError.expired)) { onCancel() }
                    } catch { }
                }
                state.attach([worker, timer])
            }
        } onCancel: {
            if state.resolve(.failure(CancellationError())) { onCancel() }
        }
    }
}
