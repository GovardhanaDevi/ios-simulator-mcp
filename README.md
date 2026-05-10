# ios-simulator-mcp

![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
![MCP](https://img.shields.io/badge/MCP-compatible-6B4FBB)
![Transport](https://img.shields.io/badge/transport-stdio-lightgrey)

A Swift MCP server that lets AI assistants control the iOS Simulator (and real devices) using the [Model Context Protocol](https://modelcontextprotocol.io). Built on the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) over stdio. UI interaction is powered by [WebDriverAgent](https://github.com/appium/WebDriverAgent) — no Python, no Appium, no private APIs.

```
Claude / MCP Client
       │  JSON-RPC (stdio)
       ▼
ios-simulator-mcp  ──→  xcrun simctl   (boot, screenshot, location, video, install)
                   ──→  WebDriverAgent  (tap, swipe, type, inspect UI)
```

---

## Prerequisites

| Requirement | Purpose |
|---|---|
| **Xcode** (with CLI tools) | `xcrun`, `xcodebuild`, `simctl` |
| **macOS 13+** | Minimum deployment target |
| `libimobiledevice` (optional) | Real device USB port-forwarding via `iproxy` |

> `libimobiledevice` is installed automatically by `Scripts/setup.sh` if Homebrew is available.

---

## Quick Start

```bash
# 1. Clone with submodules (WebDriverAgent is vendored at Vendor/WebDriverAgent)
git clone --recurse-submodules https://github.com/GovardhanaDevi/ios-simulator-mcp.git
cd ios-simulator-mcp

# 2. One-time setup: checks deps, bootstraps WDA, builds release binary
bash Scripts/setup.sh

# 3. Add to Claude Code
claude mcp add ios-simulator -- "$PWD/.build/release/ios-simulator-mcp"
```

The setup script pins WebDriverAgent to **v12.2.2** via the submodule — a known-good version tested against this server. Running `git submodule update` will stay on that pin; update the submodule intentionally if you need a newer WDA.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ios-simulator": {
      "command": "/path/to/ios-simulator-mcp/.build/release/ios-simulator-mcp"
    }
  }
}
```

### Build manually

```bash
swift build -c release
```

---

## Usage

Boot a simulator in Xcode (or via the `boot_simulator` tool), then call `start_wda` — no arguments needed if a simulator is already booted and the WDA submodule is present:

```
start_wda          # starts WebDriverAgent, waits until ready, creates a session
screenshot         # see what's on screen
tap x=195 y=420    # interact
ui_describe_all    # inspect the accessibility tree (compact, token-efficient)
```

---

## Tool Reference

### Simulator Management

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `list_simulators` | — | — | List all available simulators and their state |
| `get_booted_sim_id` | — | — | Get the UDID of the currently booted simulator |
| `boot_simulator` | `udid` or `name` | — | Boot a simulator and wait until fully ready |
| `open_simulator` | — | — | Bring Simulator.app to the foreground |
| `get_device_info` | — | `udid` | Info about a simulator (name, OS, UDID, state). Defaults to the booted simulator; pass `udid` to query any simulator |

### Screen & Media

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `screenshot` | — | `udid`, `type` (png/jpeg), `scale` (default 0.5) | Capture the screen; downscaled by default to reduce vision token cost |
| `record_video` | `output_path` | `udid`, `codec` (h264/hevc) | Start recording to a file |
| `stop_recording` | — | — | Stop recording and return the file path |

### App & Device Control

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `install_app` | `app_path` | `udid` | Install a `.app` bundle |
| `launch_app` | `bundle_id` | `udid` | Launch an app by bundle ID |
| `terminate_app` | `bundle_id` | `udid` | Terminate a running app |
| `open_url` | `url` | `udid` | Open a URL or deep link |
| `set_location` | `latitude`, `longitude` | `udid` | Simulate a GPS location |
| `clear_location` | — | `udid` | Remove the simulated location |
| `wait` | — | `seconds` (default 1) | Pause execution |

### WebDriverAgent — Setup

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `start_wda` | — | `wda_project_path`, `udid`, `port` (default 8100) | Start WDA, wait for readiness, create a session |
| `stop_wda` | — | — | Stop the WDA process |

> `wda_project_path` defaults to the vendored submodule — no argument needed after `setup.sh`.

### WebDriverAgent — UI Interaction

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `tap` | `x`, `y` | — | Tap a point on screen |
| `long_press` | `x`, `y` | `duration` (default 1.0s) | Long-press a point |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y` | `duration` (default 0.5s) | Swipe between two points |
| `type_text` | `text` | — | Type into the focused field |
| `tap_and_type` | `x`, `y`, `text` | — | Tap a field then type into it (includes a 300 ms settle pause between tap and type) |
| `press_button` | `name` | — | Press `home` or `lock` (via Simulator menu bar). `siri` also supported. `action` is forwarded to WDA but may not work on simulated devices — it is a physical-only button on iPhone 15 Pro and later |
| `shake` | — | — | Shake gesture |

### WebDriverAgent — UI Inspection

| Tool | Required args | Optional args | Description |
|---|---|---|---|
| `ui_describe_all` | — | `raw` (default false) | Compact accessibility tree (~90% fewer tokens than raw XML). Pass `raw=true` for full WDA XML |
| `ui_describe_point` | `x`, `y` | — | Describe the element under a coordinate |

---

## Real Device Support

Real devices require USB port-forwarding so WDA's HTTP server on the device is reachable on `localhost`:

```bash
# Forward device port 8100 to localhost 8100 (run in a separate terminal)
iproxy 8100 8100
```

Then pass the device UDID as the `udid` argument to `start_wda`. All subsequent WDA interaction tools (`tap`, `swipe`, `type_text`, etc.) will automatically operate on that device's active session — no further `udid` is needed for those tools.

The simctl-backed tools (`install_app`, `launch_app`, `terminate_app`, `open_url`, `set_location`, `clear_location`, `screenshot`, `record_video`, `get_device_info`) also accept an optional `udid` and work identically on real devices.

---

## How it works

Two backends, chosen by tool:

- **`xcrun simctl`** — boots/lists simulators, takes screenshots, records video, sets GPS, installs apps, opens URLs. No WDA needed.
- **WebDriverAgent** — provides a local HTTP server (`localhost:8100`) that exposes the XCTest accessibility API. Used for taps, swipes, text input, and UI inspection. Started once per session via `start_wda`. WDA sessions are lazily re-created if dropped (e.g. after an app switch), but if the WDA process itself crashes, `start_wda` must be called again.

`screenshot` downscales to 50% by default using `sips` (macOS built-in), cutting vision token cost ~4× on Retina displays. Pass `scale=1.0` for native resolution.

---

## WebDriverAgent License

WebDriverAgent is developed and maintained by the [Appium](https://github.com/appium/WebDriverAgent) project and licensed under the **Apache License 2.0**. It was originally created by Facebook. This project vendors it as a git submodule and does not modify it — see [`Vendor/WebDriverAgent/LICENSE`](Vendor/WebDriverAgent/LICENSE) for the full license text.
