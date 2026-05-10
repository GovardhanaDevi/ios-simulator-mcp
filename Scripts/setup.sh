#!/usr/bin/env bash
# setup.sh — one-time setup for ios-simulator-mcp (Option B: WDA via xcodebuild, no Appium)
set -e

echo "=== ios-simulator-mcp setup ==="

# ── 1. Check Xcode ────────────────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
  echo "❌  Xcode Command Line Tools not found. Install with: xcode-select --install"
  exit 1
fi
echo "✅  Xcode: $(xcrun --version 2>&1 | head -1)"

# ── 2. Check xcodebuild ───────────────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
  echo "❌  xcodebuild not found. Install Xcode from the App Store."
  exit 1
fi
echo "✅  xcodebuild: $(xcodebuild -version | head -1)"

# ── 3. Clone WebDriverAgent (if not already present) ─────────────────────────
WDA_DIR="${WDA_PATH:-$HOME/WebDriverAgent}"
if [ -d "$WDA_DIR" ]; then
  echo "✅  WebDriverAgent already at $WDA_DIR"
else
  echo "📥  Cloning WebDriverAgent → $WDA_DIR"
  git clone https://github.com/appium/WebDriverAgent.git "$WDA_DIR"
fi

# ── 4. Bootstrap WDA (Carthage/SPM deps) ─────────────────────────────────────
if [ -f "$WDA_DIR/Scripts/bootstrap.sh" ]; then
  echo "🔧  Running WDA bootstrap..."
  pushd "$WDA_DIR" > /dev/null
  bash Scripts/bootstrap.sh
  popd > /dev/null
  echo "✅  WDA bootstrap complete"
else
  echo "⚠️   bootstrap.sh not found — WDA may not need it (newer versions use SPM)"
fi

# ── 5. Optional: libimobiledevice for real device support ─────────────────────
if command -v brew &>/dev/null; then
  if ! command -v iproxy &>/dev/null; then
    echo "📦  Installing libimobiledevice (needed for real device USB port-forward)..."
    brew install libimobiledevice
  else
    echo "✅  libimobiledevice already installed"
  fi
else
  echo "⚠️   Homebrew not found — skip libimobiledevice (only needed for real device)"
fi

# ── 6. Build the MCP server ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔨  Building ios-simulator-mcp (release)..."
cd "$REPO_DIR"
swift build -c release

BINARY="$REPO_DIR/.build/release/ios-simulator-mcp"
echo ""
echo "✅  Build complete!"
echo ""
echo "=== Next steps ==="
echo ""
echo "1. Add to Claude Code:"
echo "   claude mcp add ios-simulator -- $BINARY"
echo ""
echo "2. Or add to Claude Desktop (~/.../claude_desktop_config.json):"
echo "   {"
echo "     \"mcpServers\": {"
echo "       \"ios-simulator\": {"
echo "         \"command\": \"$BINARY\""
echo "       }"
echo "     }"
echo "   }"
echo ""
echo "3. Boot a simulator, then use the start_wda tool with:"
echo "   wda_project_path: $WDA_DIR/WebDriverAgent.xcodeproj"
