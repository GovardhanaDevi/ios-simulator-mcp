import MCP

// Shared helpers for all tool handler files.

extension CallTool.Result {
    /// Convenience: wrap a plain string as a successful text result.
    static func text(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: false)
    }
}
