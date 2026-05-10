import Foundation

enum SimulatorError: Error, LocalizedError {
    case noBootedSimulator
    case alreadyRecording
    case notRecording
    case jsonParseError(String)

    var errorDescription: String? {
        switch self {
        case .noBootedSimulator:       return "No booted iOS Simulator found. Use boot_simulator first."
        case .alreadyRecording:        return "A recording is already in progress. Call stop_recording first."
        case .notRecording:            return "No recording is currently in progress."
        case .jsonParseError(let m):   return "Failed to parse simctl JSON: \(m)"
        }
    }
}

actor SimulatorManager {

    // MARK: - UDID cache

    private var cachedUDID: String?

    /// Returns the UDID of the currently booted simulator, caching the result.
    func bootedUDID() async throws -> String {
        if let cached = cachedUDID { return cached }
        let udid = try await findBootedUDID()
        cachedUDID = udid
        return udid
    }

    func invalidateCache() { cachedUDID = nil }

    // MARK: - Video recording

    private var recordingProcess: Process?
    private var recordingOutputPath: String?

    func startRecording(udid: String, outputPath: String, codec: String) throws {
        guard recordingProcess == nil else { throw SimulatorError.alreadyRecording }

        let process = try launchBackground(
            "/usr/bin/xcrun",
            ["simctl", "io", udid, "recordVideo", "--codec", codec, "--force", outputPath]
        ) { line in
            log("[recorder] \(line)")
        }
        recordingProcess = process
        recordingOutputPath = outputPath
    }

    func stopRecording() throws -> String {
        guard let process = recordingProcess else { throw SimulatorError.notRecording }
        let path = recordingOutputPath ?? "unknown"
        process.terminate()
        process.waitUntilExit()
        recordingProcess = nil
        recordingOutputPath = nil
        return path
    }

    var isRecording: Bool { recordingProcess != nil }

    // MARK: - Private helpers

    private func findBootedUDID() async throws -> String {
        let json = try await shell("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "--json"])
        guard let data = json.data(using: .utf8) else {
            throw SimulatorError.jsonParseError("empty output")
        }
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        for (_, devices) in list.devices {
            if let booted = devices.first(where: { $0.isBooted }) {
                return booted.udid
            }
        }
        throw SimulatorError.noBootedSimulator
    }
}
