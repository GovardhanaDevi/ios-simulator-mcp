import Foundation

enum ShellError: Error, LocalizedError {
    case commandFailed(output: String, exitCode: Int32)
    case commandNotFound(String)
    case timeout(command: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let out, let code): return "Exit \(code): \(out)"
        case .commandNotFound(let cmd):         return "Not found: \(cmd)"
        case .timeout(let cmd, let secs):       return "Command timed out after \(secs)s: \(cmd)"
        }
    }
}

/// Runs a command asynchronously. Kills the process if it exceeds `timeout` seconds.
func shell(_ executable: String, _ arguments: [String] = [], input: String? = nil, timeout: Int = 30) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try shellSync(executable, arguments, input: input, timeout: timeout)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Launches a long-running process and returns it immediately. Caller must call terminate() when done.
func launchBackground(_ executable: String, _ arguments: [String], outputHandler: @escaping @Sendable (String) -> Void) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
            outputHandler(text)
        }
    }

    process.terminationHandler = { _ in
        outputPipe.fileHandleForReading.readabilityHandler = nil
    }

    try process.run()
    return process
}

// MARK: - Private sync helper

private func shellSync(_ executable: String, _ arguments: [String], input: String? = nil, timeout: Int = 30) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    if let inputString = input {
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        if let data = inputString.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
            inputPipe.fileHandleForWriting.closeFile()
        }
    }

    // Drain both pipes concurrently via readabilityHandlers to prevent deadlock
    // when output exceeds the ~64 KB kernel pipe buffer. waitUntilExit() alone would
    // deadlock if the process fills the buffer before we read — the process blocks
    // on write, we block on waitUntilExit(), neither proceeds.
    //
    // DataBuffer is @unchecked Sendable: safety is guaranteed by the DispatchSemaphore
    // protocol — the last append happens-before signal(), which happens-before wait(),
    // which happens-before our final read. No lock needed.
    final class DataBuffer: @unchecked Sendable { var data = Data() }
    let outputBuf  = DataBuffer()
    let errorBuf   = DataBuffer()
    let outputDone = DispatchSemaphore(value: 0)
    let errorDone  = DispatchSemaphore(value: 0)

    outputPipe.fileHandleForReading.readabilityHandler = { fh in
        let chunk = fh.availableData
        if chunk.isEmpty { outputDone.signal() } else { outputBuf.data.append(chunk) }
    }
    errorPipe.fileHandleForReading.readabilityHandler = { fh in
        let chunk = fh.availableData
        if chunk.isEmpty { errorDone.signal() } else { errorBuf.data.append(chunk) }
    }

    try process.run()

    // Kill the process if it exceeds the timeout
    let deadline = DispatchTime.now() + .seconds(timeout)
    let killItem = DispatchWorkItem {
        if process.isRunning {
            log("[shell] timeout after \(timeout)s — killing \(executable) \(arguments.joined(separator: " "))")
            process.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: deadline, execute: killItem)

    process.waitUntilExit()
    killItem.cancel()

    // Wait for both pipes to drain fully (EOF is delivered once the process exits
    // and the write-end of each pipe is closed). The semaphore signal happens-before
    // our read of outputData/errorData, so no lock is needed.
    outputDone.wait()
    errorDone.wait()
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil

    // Timed out: terminationReason is .uncaughtSignal (SIGTERM)
    if process.terminationReason == .uncaughtSignal && process.terminationStatus != 0 {
        throw ShellError.timeout(command: "\(executable) \(arguments.joined(separator: " "))", seconds: timeout)
    }

    let output = String(data: outputBuf.data, encoding: .utf8) ?? ""
    let error  = String(data: errorBuf.data,  encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let message = error.isEmpty ? output : error
        throw ShellError.commandFailed(
            output: message.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus
        )
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Write to stderr — stdout is reserved for the MCP protocol channel.
func log(_ message: String) {
    let stderr = FileHandle.standardError
    if let data = (message + "\n").data(using: .utf8) {
        stderr.write(data)
    }
}
