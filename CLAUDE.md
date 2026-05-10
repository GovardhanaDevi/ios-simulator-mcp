# iOS Simulator MCP — Implementation Guide for Claude Code

## Goal
Build a Swift MCP server (`ios-simulator-mcp`) that lets AI assistants control the iOS Simulator
(and real devices) via the Model Context Protocol.

- **Language**: Swift 6.0
- **Transport**: stdio (MCP SDK `StdioTransport`)
- **Build system**: Swift Package Manager executable
- **UI interaction backend**: WebDriverAgent (WDA) over HTTP — NO Python idb, NO private APIs
- **Other tools**: `xcrun simctl` for everything WDA doesn't cover

The `Package.swift` and directory structure already exist. Implement all source files from scratch.

---

## Architecture

```
Claude / MCP Client
        │  JSON-RPC over stdio
        ▼
ios-simulator-mcp (Swift binary)
        │
        ├── Process() → xcrun simctl ──→ boot, list, screenshot, location, video, install
        │
        └── URLSession (HTTP) ──────────→ WebDriverAgent :8100
                                                │  XCTest public API
                                                ▼
                                      iOS Simulator or Real Device
```

---

## Prerequisites (document in README, do NOT auto-install)

1. **Xcode** — provides `xcrun`, `xcodebuild`, `simctl`
2. **WebDriverAgent source** — cloned by the user or via `Scripts/setup.sh`
3. **For real device**: `brew install libimobiledevice` (provides `iproxy` for USB port-forward)

WDA is started by the MCP itself using `xcodebuild test`. No Appium, no Node.js required.

---

## File Structure to Implement

```
Sources/IOSSimulatorMCP/
├── main.swift
├── Shell.swift
├── Models/
│   ├── SimctlModels.swift
│   └── WDAModels.swift
├── Managers/
│   ├── SimulatorManager.swift
│   └── WDAManager.swift
└── Tools/
    ├── ToolDefinitions.swift
    ├── ToolDispatcher.swift
    ├── SimctlTools.swift
    └── WDATools.swift
```

---

## Step-by-Step Implementation

### Step 1 — `Shell.swift`

Async wrapper around `Foundation.Process`. Used by `SimctlTools` and `WDAManager`.

```swift
import Foundation

enum ShellError: Error, LocalizedError {
    case commandFailed(output: String, exitCode: Int32)
    case commandNotFound(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let out, let code): return "Exit \(code): \(out)"
        case .commandNotFound(let cmd): return "Not found: \(cmd)"
        }
    }
}

/// Runs a command asynchronously on a background thread so the async executor is not blocked.
func shell(_ executable: String, _ arguments: [String] = [], input: String? = nil) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try shellSync(executable, arguments, input: input)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Launches a long-running process (e.g. xcodebuild, recordVideo) and returns it immediately.
/// Caller owns the Process and must call terminate() when done.
func launchBackground(_ executable: String, _ arguments: [String], outputHandler: @escaping @Sendable (String) -> Void) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe   // merge stderr into stdout

    outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
            outputHandler(text)
        }
    }

    try process.run()
    return process
}

// MARK: - Private sync helper

private func shellSync(_ executable: String, _ arguments: [String], input: String? = nil) throws -> String {
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

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error  = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),  encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let message = error.isEmpty ? output : error
        throw ShellError.commandFailed(output: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                       exitCode: process.terminationStatus)
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Write to stderr (not stdout — stdout is the MCP protocol channel).
func log(_ message: String) {
    var stderr = FileHandle.standardError
    if let data = (message + "\n").data(using: .utf8) {
        stderr.write(data)
    }
}
```

---

### Step 2 — `Models/SimctlModels.swift`

Codable structs for `xcrun simctl list devices --json` output.

```swift
import Foundation

struct SimctlDeviceList: Codable {
    let devices: [String: [SimctlDevice]]
}

struct SimctlDevice: Codable {
    let udid: String
    let name: String
    let state: String          // "Booted", "Shutdown", "Booting"
    let isAvailable: Bool
    let deviceTypeIdentifier: String?
    let lastBootedAt: String?

    var isBooted: Bool { state == "Booted" }
}

extension SimctlDevice {
    /// Human-readable OS name derived from the runtime key.
    /// e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5"
    static func osName(from runtimeKey: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtimeKey.hasPrefix(prefix) else { return runtimeKey }
        let slug = String(runtimeKey.dropFirst(prefix.count))  // e.g. "iOS-17-5"
        return slug.replacingOccurrences(of: "-", with: " ")
                   .replacingOccurrences(of: "  ", with: " ")  // cleanup double spaces
    }
}
```

---

### Step 3 — `Models/WDAModels.swift`

Codable types for WDA JSON requests and responses.

```swift
import Foundation

// MARK: - Generic WDA Response envelope

struct WDAResponse<T: Decodable>: Decodable {
    let value: T?
    let sessionId: String?
}

struct WDASessionValue: Decodable {
    let sessionId: String
    let capabilities: WDACapabilities?
}

struct WDACapabilities: Decodable {
    let bundleId: String?
    let deviceName: String?
    let platformVersion: String?
}

struct WDAStatus: Decodable {
    let ready: Bool?
    let message: String?
}

// MARK: - Session create request

struct WDACreateSessionRequest: Encodable {
    let capabilities: WDASessionCapabilities

    struct WDASessionCapabilities: Encodable {
        let firstMatch: [[String: String]]
        let alwaysMatch: WDAAlwaysMatch

        struct WDAAlwaysMatch: Encodable {
            var bundleId: String?
            var shouldWaitForQuiescence: Bool = false

            enum CodingKeys: String, CodingKey {
                case bundleId
                case shouldWaitForQuiescence = "wda:shouldWaitForQuiescence"
            }
        }
    }

    static func make(bundleId: String? = nil) -> WDACreateSessionRequest {
        WDACreateSessionRequest(
            capabilities: .init(
                firstMatch: [[:]],
                alwaysMatch: .init(bundleId: bundleId, shouldWaitForQuiescence: false)
            )
        )
    }
}

// MARK: - W3C Actions (tap, swipe, long press)

struct WDAActionsRequest: Encodable {
    let actions: [WDAAction]

    struct WDAAction: Encodable {
        let type: String       // "pointer"
        let id: String         // "finger1"
        let parameters: WDAPointerParameters
        let actions: [WDAActionStep]
    }

    struct WDAPointerParameters: Encodable {
        let pointerType: String  // "touch"
    }

    struct WDAActionStep: Encodable {
        let type: String          // "pointerMove" | "pointerDown" | "pointerUp" | "pause"
        var duration: Int?        // ms
        var x: Double?
        var y: Double?
        var button: Int?
    }

    // MARK: Convenience builders

    static func tap(x: Double, y: Double) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: x, y: y),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pause", duration: 100),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }

    static func longPress(x: Double, y: Double, durationMs: Int) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: x, y: y),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pause", duration: durationMs),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }

    static func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int = 500) -> WDAActionsRequest {
        WDAActionsRequest(actions: [
            WDAAction(type: "pointer", id: "finger1",
                      parameters: WDAPointerParameters(pointerType: "touch"),
                      actions: [
                          WDAActionStep(type: "pointerMove", duration: 0, x: fromX, y: fromY),
                          WDAActionStep(type: "pointerDown", button: 0),
                          WDAActionStep(type: "pointerMove", duration: durationMs, x: toX, y: toY),
                          WDAActionStep(type: "pointerUp", button: 0),
                      ])
        ])
    }
}

// MARK: - Keys (type text)

struct WDAKeysRequest: Encodable {
    let value: [String]

    static func make(_ text: String) -> WDAKeysRequest {
        WDAKeysRequest(value: text.map { String($0) })
    }
}

// MARK: - Button press

struct WDAButtonRequest: Encodable {
    let name: String   // "home" | "volumeup" | "volumedown" | "lock" | "siri"
}

// MARK: - Coordinate describe

struct WDACoordinateRequest: Encodable {
    let x: Double
    let y: Double
}

// MARK: - Launch app (activate)
struct WDAActivateAppRequest: Encodable {
    let bundleId: String
}

struct WDATerminateAppRequest: Encodable {
    let bundleId: String
}
```

---

### Step 4 — `Managers/SimulatorManager.swift`

Actor that caches the booted simulator UDID and manages the video recording process.

```swift
import Foundation

enum SimulatorError: Error, LocalizedError {
    case noBootedSimulator
    case alreadyRecording
    case notRecording
    case jsonParseError(String)

    var errorDescription: String? {
        switch self {
        case .noBootedSimulator:   return "No booted iOS Simulator found. Use boot_simulator first."
        case .alreadyRecording:    return "A recording is already in progress. Call stop_recording first."
        case .notRecording:        return "No recording is currently in progress."
        case .jsonParseError(let m): return "Failed to parse simctl JSON: \(m)"
        }
    }
}

actor SimulatorManager {

    // MARK: - UDID cache

    private var cachedUDID: String?

    /// Returns the UDID of the currently booted simulator.
    /// Caches the result; call invalidateCache() after booting a new one.
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
```

---

### Step 5 — `Managers/WDAManager.swift`

Actor that starts WDA via `xcodebuild test`, waits for readiness, manages the session.

Key behaviour:
- `start(udid:wdaProjectPath:)` — launches `xcodebuild test` in background, watches output for `ServerURLHere->http://...` to detect readiness.
- `waitForReady()` — polls `GET /status` with exponential backoff, timeout 120 s.
- `session(for:)` — lazily creates a WDA session (optionally with a bundleId), caches `sessionId`.
- Every HTTP request goes through `request(_:method:body:)` which is a generic JSON send/receive helper.

```swift
import Foundation

enum WDAError: Error, LocalizedError {
    case notStarted
    case startTimeout
    case sessionFailed(String)
    case httpError(Int, String)
    case decodingError(String)
    case noSession

    var errorDescription: String? {
        switch self {
        case .notStarted:          return "WDA is not running. Call start_wda first."
        case .startTimeout:        return "WDA did not become ready within 120 seconds."
        case .sessionFailed(let m): return "WDA session creation failed: \(m)"
        case .httpError(let c, let m): return "WDA HTTP \(c): \(m)"
        case .decodingError(let m): return "WDA response decode error: \(m)"
        case .noSession:           return "No active WDA session. WDA may have restarted."
        }
    }
}

actor WDAManager {

    // MARK: - State

    private var xcodebuildProcess: Process?
    private var sessionId: String?
    private var wdaPort: Int = 8100
    private let urlSession = URLSession.shared

    var baseURL: URL { URL(string: "http://localhost:\(wdaPort)")! }

    // MARK: - Lifecycle

    /// Start WDA for the given simulator UDID using xcodebuild.
    /// wdaProjectPath: path to WebDriverAgent.xcodeproj on disk.
    func start(udid: String, wdaProjectPath: String, port: Int = 8100) async throws {
        self.wdaPort = port

        // Stop any existing instance
        if let existing = xcodebuildProcess, existing.isRunning {
            existing.terminate()
            existing.waitUntilExit()
        }
        sessionId = nil

        let derivedDataPath = NSTemporaryDirectory() + "wda-deriveddata"

        let args: [String] = [
            "test",
            "-project", wdaProjectPath,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "id=\(udid)",
            "-derivedDataPath", derivedDataPath,
            "USE_PORT=\(port)",
            "MJPEG_SERVER_PORT=\(port + 1000)",
        ]

        log("[WDA] Starting: xcodebuild \(args.joined(separator: " "))")

        let process = try launchBackground("/usr/bin/xcodebuild", args) { line in
            log("[WDA] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        xcodebuildProcess = process
    }

    /// Poll GET /status until WDA reports ready or timeout (default 120 s).
    func waitForReady(timeoutSeconds: Double = 120) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var delay: UInt64 = 1_000_000_000  // 1 s

        while Date() < deadline {
            if let status = try? await getStatus(), status.ready == true {
                log("[WDA] Ready ✓")
                return
            }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 8_000_000_000) // cap at 8 s
        }
        throw WDAError.startTimeout
    }

    func stop() {
        xcodebuildProcess?.terminate()
        xcodebuildProcess = nil
        sessionId = nil
    }

    // MARK: - Session

    /// Get (or lazily create) a WDA session. Pass bundleId to launch an app.
    func session(bundleId: String? = nil) async throws -> String {
        if let existing = sessionId {
            // Verify it's still alive
            if (try? await getStatus()) != nil { return existing }
            sessionId = nil
        }

        let req = WDACreateSessionRequest.make(bundleId: bundleId)
        let data = try await post("/session", body: req)

        struct SessionResp: Decodable {
            struct Val: Decodable { let sessionId: String }
            let value: Val
        }

        guard let resp = try? JSONDecoder().decode(SessionResp.self, from: data),
              !resp.value.sessionId.isEmpty else {
            throw WDAError.sessionFailed("Could not parse sessionId from response")
        }

        sessionId = resp.value.sessionId
        log("[WDA] Session: \(resp.value.sessionId)")
        return resp.value.sessionId
    }

    func deleteSession() async throws {
        guard let sid = sessionId else { return }
        _ = try? await delete("/session/\(sid)")
        sessionId = nil
    }

    // MARK: - UI Actions (called by WDATools)

    func tap(x: Double, y: Double) async throws {
        let sid = try await session()
        let body = WDAActionsRequest.tap(x: x, y: y)
        _ = try await post("/session/\(sid)/actions", body: body)
    }

    func longPress(x: Double, y: Double, durationSeconds: Double) async throws {
        let sid = try await session()
        let body = WDAActionsRequest.longPress(x: x, y: y, durationMs: Int(durationSeconds * 1000))
        _ = try await post("/session/\(sid)/actions", body: body)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationSeconds: Double = 0.5) async throws {
        let sid = try await session()
        let body = WDAActionsRequest.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                           durationMs: Int(durationSeconds * 1000))
        _ = try await post("/session/\(sid)/actions", body: body)
    }

    func typeText(_ text: String) async throws {
        let sid = try await session()
        let body = WDAKeysRequest.make(text)
        _ = try await post("/session/\(sid)/wda/keys", body: body)
    }

    func pressButton(_ name: String) async throws {
        let sid = try await session()
        let body = WDAButtonRequest(name: name)
        _ = try await post("/session/\(sid)/wda/pressButton", body: body)
    }

    func shake() async throws {
        let sid = try await session()
        _ = try await post("/session/\(sid)/wda/shake", body: EmptyBody())
    }

    func uiSource() async throws -> String {
        let data = try await get("/source")
        return String(data: data, encoding: .utf8) ?? ""
    }

    func describeElement(x: Double, y: Double) async throws -> String {
        let sid = try await session()
        let body = WDACoordinateRequest(x: x, y: y)
        let data = try await post("/session/\(sid)/wda/element/atCoordinate", body: body)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func launchApp(bundleId: String) async throws {
        let sid = try await session()
        let body = WDAActivateAppRequest(bundleId: bundleId)
        _ = try await post("/session/\(sid)/wda/apps/activate", body: body)
    }

    func terminateApp(bundleId: String) async throws {
        let sid = try await session()
        let body = WDATerminateAppRequest(bundleId: bundleId)
        _ = try await post("/session/\(sid)/wda/apps/terminate", body: body)
    }

    // MARK: - HTTP helpers

    private func getStatus() async throws -> WDAStatus? {
        let data = try await get("/status")
        struct StatusResp: Decodable { let value: WDAStatus? }
        return try? JSONDecoder().decode(StatusResp.self, from: data).value
    }

    private func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        return try await execute(req)
    }

    private func post<B: Encodable>(_ path: String, body: B) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await execute(req)
    }

    private func delete(_ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        return try await execute(req)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WDAError.httpError(http.statusCode, body)
        }
        return data
    }
}

private struct EmptyBody: Encodable {}
```

---

### Step 6 — `Tools/ToolDefinitions.swift`

Define all 27 `Tool` objects with proper JSON Schema input schemas.
Use the pattern: `.object(["type": .string("object"), "properties": .object([...]), "required": .array([...])])`.

Tools grouped by backend:

**xcrun simctl tools (10):**
`list_simulators`, `get_booted_sim_id`, `boot_simulator`, `open_simulator`, `get_device_info`,
`screenshot`, `record_video`, `stop_recording`, `set_location`, `clear_location`,
`install_app`, `open_url`, `wait`

**WDA tools (14):**
`start_wda`, `stop_wda`,
`tap`, `long_press`, `swipe`, `type_text`, `tap_and_type`,
`press_button`, `shake`,
`ui_describe_all`, `ui_describe_point`,
`launch_app`, `terminate_app`

Implement `enum ToolDefinitions` with a `static let allTools: [Tool]` property.

Each Tool needs:
- `name` — snake_case
- `description` — one clear sentence
- `inputSchema` — proper JSON Schema wrapped in MCP `Value`

Example for a tool with required + optional params:
```swift
Tool(
    name: "tap",
    description: "Tap at x,y coordinates on the iOS Simulator screen.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "x": .object(["type": .string("number"), "description": .string("X coordinate in points")]),
            "y": .object(["type": .string("number"), "description": .string("Y coordinate in points")]),
            "udid": .object(["type": .string("string"), "description": .string("Simulator UDID (optional, uses booted sim)")]),
        ]),
        "required": .array([.string("x"), .string("y")]),
    ])
)
```

Implement ALL tools with sensible descriptions and complete schemas.

---

### Step 7 — `Tools/SimctlTools.swift`

Functions that implement each xcrun simctl-based tool. Each function takes `[String: Value]?` arguments and returns `CallTool.Result`.

Key implementations:

```
list_simulators     → xcrun simctl list devices --json → parse → format as text
get_booted_sim_id   → SimulatorManager.bootedUDID()
boot_simulator      → xcrun simctl boot <udid or name>; SimulatorManager.invalidateCache()
open_simulator      → open -a Simulator
get_device_info     → xcrun simctl list devices booted --json → detailed info
screenshot          → xcrun simctl io <udid> screenshot --type <type> <output_path>
                       read file → return as .image(data:mimeType:) content
record_video        → SimulatorManager.startRecording(udid:outputPath:codec:)
stop_recording      → SimulatorManager.stopRecording()
set_location        → xcrun simctl location <udid> set <lat,lng>
clear_location      → xcrun simctl location <udid> clear
install_app         → xcrun simctl install <udid> <app_path>
open_url            → xcrun simctl openurl <udid> <url>
wait                → Task.sleep(for: .seconds(duration))
```

For `screenshot`, read the PNG/JPEG bytes and return:
```swift
return CallTool.Result(content: [.image(data: imageData, mimeType: "image/png")], isError: false)
```

For `boot_simulator` when name is provided instead of UDID:
- Run `xcrun simctl list devices --json`, find first matching device by name, use its udid.

---

### Step 8 — `Tools/WDATools.swift`

Functions that implement WDA-backed tools. Each takes args + `WDAManager` and returns `CallTool.Result`.

```
start_wda         → WDAManager.start(udid:wdaProjectPath:port:)
                    WDAManager.waitForReady()
stop_wda          → WDAManager.stop()
tap               → WDAManager.tap(x:y:)
long_press        → WDAManager.longPress(x:y:durationSeconds:)
swipe             → WDAManager.swipe(fromX:fromY:toX:toY:durationSeconds:)
type_text         → WDAManager.typeText(_:)
tap_and_type      → WDAManager.tap(x:y:) then WDAManager.typeText(_:)
press_button      → WDAManager.pressButton(_:)  // "home"|"volumeup"|"volumedown"|"lock"|"siri"
shake             → WDAManager.shake()
ui_describe_all   → WDAManager.uiSource()  // returns XML string
ui_describe_point → WDAManager.describeElement(x:y:)
launch_app        → WDAManager.launchApp(bundleId:)
terminate_app     → WDAManager.terminateApp(bundleId:)
```

For `start_wda`, required args:
- `wda_project_path` (String) — full path to `WebDriverAgent.xcodeproj`
- `udid` (String, optional) — defaults to booted sim UDID

---

### Step 9 — `Tools/ToolDispatcher.swift`

Routes `CallTool` requests. Pattern:

```swift
import MCP

struct ToolDispatcher: Sendable {
    let simulatorManager: SimulatorManager
    let wdaManager: WDAManager

    func dispatch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        do {
            return try await route(params)
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    private func route(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments
        switch params.name {
        // --- simctl ---
        case "list_simulators":    return try await listSimulators(args)
        case "get_booted_sim_id":  return try await getBootedSimId(args)
        case "boot_simulator":     return try await bootSimulator(args)
        case "open_simulator":     return try await openSimulator(args)
        case "get_device_info":    return try await getDeviceInfo(args)
        case "screenshot":         return try await screenshot(args)
        case "record_video":       return try await recordVideo(args)
        case "stop_recording":     return try await stopRecording(args)
        case "set_location":       return try await setLocation(args)
        case "clear_location":     return try await clearLocation(args)
        case "install_app":        return try await installApp(args)
        case "open_url":           return try await openURL(args)
        case "wait":               return try await wait(args)
        // --- WDA ---
        case "start_wda":          return try await startWDA(args)
        case "stop_wda":           return try await stopWDA(args)
        case "tap":                return try await tap(args)
        case "long_press":         return try await longPress(args)
        case "swipe":              return try await swipe(args)
        case "type_text":          return try await typeText(args)
        case "tap_and_type":       return try await tapAndType(args)
        case "press_button":       return try await pressButton(args)
        case "shake":              return try await shake(args)
        case "ui_describe_all":    return try await uiDescribeAll(args)
        case "ui_describe_point":  return try await uiDescribePoint(args)
        case "launch_app":         return try await launchApp(args)
        case "terminate_app":      return try await terminateApp(args)
        default:
            return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    }
}
```

Put the actual handler implementations inline in this file, calling into `SimctlTools.swift` and `WDATools.swift` helpers.

---

### Step 10 — `main.swift`

Entry point. Create server, register handlers, start.

```swift
import Foundation
import MCP

// Create shared managers (actors — thread-safe)
let simulatorManager = SimulatorManager()
let wdaManager       = WDAManager()
let dispatcher       = ToolDispatcher(simulatorManager: simulatorManager, wdaManager: wdaManager)

// Create MCP server
let server = Server(
    name: "ios-simulator-mcp",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

// Register handlers
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: ToolDefinitions.allTools)
}

await server.withMethodHandler(CallTool.self) { params in
    try await dispatcher.dispatch(params)
}

// Start stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)
log("[MCP] ios-simulator-mcp running on stdio")
await server.waitUntilCompleted()
```

---

## WDA Setup Flow (for README)

**One-time setup:**
```bash
# 1. Clone WebDriverAgent
git clone https://github.com/appium/WebDriverAgent.git ~/WebDriverAgent

# 2. Install dependencies (run once in WDA directory)
cd ~/WebDriverAgent
./Scripts/bootstrap.sh   # installs Carthage deps if needed

# 3. Build WDA for simulator (optional — MCP can trigger this via xcodebuild)
xcodebuild build-for-testing \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath /tmp/wda-deriveddata
```

**Each session (MCP will do this automatically via `start_wda` tool):**
```bash
# The start_wda MCP tool runs this under the hood:
xcodebuild test \
  -project ~/WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'id=<booted-sim-udid>' \
  -derivedDataPath /tmp/wda-deriveddata \
  USE_PORT=8100
```

WDA is ready when `GET http://localhost:8100/status` returns `{"value":{"ready":true,...}}`.

**For real device (extra step):**
```bash
# Port-forward USB to localhost
iproxy 8100 8100   # from libimobiledevice
```

---

## MCP Client Configuration

### Claude Code
```bash
claude mcp add ios-simulator -- /path/to/.build/release/ios-simulator-mcp
```

### Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`)
```json
{
  "mcpServers": {
    "ios-simulator": {
      "command": "/path/to/ios-simulator-mcp/.build/release/ios-simulator-mcp"
    }
  }
}
```

---

## Build & Test

```bash
# Debug build
swift build

# Release build (for production use)
swift build -c release

# Run directly to test stdio
.build/debug/ios-simulator-mcp
```

---

## Implementation Notes

- **Swift 6 strict concurrency**: all closures passed to `withMethodHandler` must be `@Sendable`. Actors handle isolation correctly.
- **Never write to stdout** from tool handlers — stdout is the MCP protocol channel. Use `log()` (writes to stderr).
- **Tool errors**: catch all errors in `ToolDispatcher.dispatch()` and return `isError: true` content rather than throwing — MCP clients handle this better.
- **Value extraction**: use `params.arguments?["key"]?.stringValue`, `.doubleValue`, `.intValue`, `.boolValue`.
- **WDA session**: the manager creates a session lazily. If WDA restarts, the session becomes invalid — detect this (HTTP 404/500) and recreate.
- **Screenshots**: `xcrun simctl io <udid> screenshot` writes to a temp file; read the bytes and return as `.image(data:mimeType:)` content.
- **Record video**: `xcrun simctl io <udid> recordVideo` blocks until killed. Use `launchBackground()` and store the `Process` in `SimulatorManager`.

---

## Coding Standards

- Use `actor` for all shared mutable state (`SimulatorManager`, `WDAManager`)
- Use `async throws` everywhere — no callbacks
- Group related code with `// MARK: -` comments
- All public functions need a one-line doc comment
- No force-unwraps (`!`) — use `guard let` / `try` / `?? default`
