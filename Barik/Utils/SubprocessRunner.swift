import Foundation
import os

/// Centralized, timeout-aware, concurrency-capped subprocess runner.
///
/// Solves three problems present in the previous direct `Process` usage:
/// 1. Pipe drain deadlock — output is drained asynchronously via `readabilityHandler`
///    so children never block writing to a full pipe buffer.
/// 2. No timeout — every call has a wall-clock deadline; runaway children are
///    SIGTERM'd then SIGKILL'd.
/// 3. Thread explosion — a global semaphore caps concurrent subprocesses, preventing
///    GCD worker thread exhaustion that previously froze the app.
enum SubprocessRunner {
    struct Result {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        let timedOut: Bool
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.barik",
        category: "SubprocessRunner")

    /// Caps concurrent subprocesses across the whole app.
    /// Sized to handle a bursty mix (aerospace + osascript + bash) without
    /// approaching GCD's worker thread cap (~64).
    private static let concurrencyLimit = DispatchSemaphore(value: 4)

    /// Dedicated queue so subprocess waits never consume GCD's shared worker pool.
    private static let queue = DispatchQueue(
        label: "app.barik.subprocess", attributes: .concurrent)

    /// Runs an executable, blocking the calling thread until exit or timeout.
    /// MUST NOT be called from the main thread.
    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) -> Result? {
        assert(!Thread.isMainThread, "SubprocessRunner.run must not be called on the main thread")

        concurrencyLimit.wait()
        defer { concurrencyLimit.signal() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if stdin != nil {
            process.standardInput = stdinPipe
        }

        // Drain pipes asynchronously to avoid deadlock when output exceeds the
        // OS pipe buffer (typically 16-64KB).
        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            logger.error(
                "Failed to launch \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        if let stdin = stdin {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let timedOut = terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            let pid = process.processIdentifier
            logger.fault(
                "Subprocess timed out after \(timeout, privacy: .public)s: \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)"
            )
            process.terminate()
            // Give SIGTERM a brief grace period, then escalate to SIGKILL.
            if terminationSemaphore.wait(timeout: .now() + 0.2) == .timedOut {
                kill(pid, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 0.5)
            }
        }

        // Drain any remaining buffered data once the readability handlers settle.
        let leftoverOut =
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let leftoverErr =
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        stdoutBuffer.append(leftoverOut)
        stderrBuffer.append(leftoverErr)

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        return Result(
            stdout: stdoutBuffer.snapshot(),
            stderr: stderrBuffer.snapshot(),
            exitCode: process.terminationStatus,
            timedOut: timedOut)
    }

    /// Convenience: run on the dedicated background queue and deliver the result on `completion`'s queue.
    static func runAsync(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval,
        completion: @escaping (Result?) -> Void
    ) {
        queue.async {
            let result = run(
                executable: executable, arguments: arguments,
                stdin: stdin, timeout: timeout)
            completion(result)
        }
    }
}

/// Thread-safe Data accumulator. `readabilityHandler` callbacks fire on Foundation-owned threads.
private final class DataBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
