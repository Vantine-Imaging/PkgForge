import Foundation

struct ProcessResult: Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitStatus == 0 }

    /// stderr first when it carries anything — that is where `pkgbuild` and
    /// `codesign` put the message worth reading.
    var message: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        return output
    }
}

enum ProcessRunnerError: LocalizedError {
    case executableMissing(String)
    case launchFailed(String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            "Required tool not found at \(path)."
        case .launchFailed(let path, let underlying):
            "Could not run \(path): \(underlying)"
        }
    }
}

/// Collects both pipes behind a lock. The readability handlers fire on
/// arbitrary queues, so every mutation is guarded.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    // `ditto -V` emits two lines per file. On a large bundle that is tens of
    // megabytes of text nobody reads — only the tail matters for diagnosing a
    // failure, so older output is dropped.
    private static let limit = 256 * 1024

    private func append(_ data: Data, to buffer: inout Data) {
        buffer.append(data)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
        }
    }

    func appendOut(_ data: Data) { lock.withLock { append(data, to: &out) } }
    func appendErr(_ data: Data) { lock.withLock { append(data, to: &err) } }

    var strings: (String, String) {
        lock.withLock { (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
    }
}

/// Tracks the three completion signals — stdout EOF, stderr EOF, process
/// exit — and resumes the continuation exactly once, after all three.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var openPipes = 2
    private var exitStatus: Int32?
    private var resumed = false
    private let finish: @Sendable (Int32) -> Void
    private let fail: @Sendable (Error) -> Void

    init(finish: @escaping @Sendable (Int32) -> Void, fail: @escaping @Sendable (Error) -> Void) {
        self.finish = finish
        self.fail = fail
    }

    func pipeClosed() {
        lock.lock()
        openPipes -= 1
        let status = readyStatusLocked()
        lock.unlock()
        if let status { finish(status) }
    }

    func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let ready = readyStatusLocked()
        lock.unlock()
        if let ready { finish(ready) }
    }

    func abort(_ error: Error) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        fail(error)
    }

    private func readyStatusLocked() -> Int32? {
        guard !resumed, openPipes == 0, let exitStatus else { return nil }
        resumed = true
        return exitStatus
    }
}

/// Holds the running process so a cancelled Task can terminate it.
///
/// `Task.cancel()` on its own does nothing to a `Process` — without this a
/// cancelled build leaves `ditto` copying gigabytes in the background while the
/// UI claims it stopped.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }
}

/// Runs a command-line tool and returns once both pipes have been drained.
///
/// Draining before `waitUntilExit()` is not optional (N-1): `pkgbuild` and
/// `codesign` produce more than the 64 KB pipe buffer on a large payload, and
/// a process blocked writing into a full pipe never exits.
enum ProcessRunner {

    /// - Parameter onOutput: called with each chunk as it arrives, tagged with
    ///   whether it came from stderr, so the UI log stays live during a build.
    static func run(
        _ executablePath: String,
        _ arguments: [String],
        onOutput: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ProcessRunnerError.executableMissing(executablePath)
        }

        let collector = OutputCollector()
        let handle = ProcessHandle()

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = RunState(
                    finish: { continuation.resume(returning: $0) },
                    fail: { continuation.resume(throwing: $0) }
                )

                let process = Process()
                // Absolute path, always (N-2). No PATH lookup, no `/bin/sh -c`.
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        state.pipeClosed()
                    } else {
                        collector.appendOut(data)
                        onOutput?(String(decoding: data, as: UTF8.self), false)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        state.pipeClosed()
                    } else {
                        collector.appendErr(data)
                        onOutput?(String(decoding: data, as: UTF8.self), true)
                    }
                }

                process.terminationHandler = { finished in
                    state.processExited(status: finished.terminationStatus)
                }

                do {
                    try process.run()
                    handle.attach(process)
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.abort(
                        ProcessRunnerError.launchFailed(executablePath, underlying: error.localizedDescription)
                    )
                }
            }
        } onCancel: {
            handle.cancel()
        }

        try Task.checkCancellation()

        let (out, err) = collector.strings
        return ProcessResult(exitStatus: status, standardOutput: out, standardError: err)
    }
}
