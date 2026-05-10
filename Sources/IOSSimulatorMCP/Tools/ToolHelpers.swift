import MCP

// Shared helpers for all tool handler files.

extension CallTool.Result {
    /// Convenience: wrap a plain string as a successful text result.
    static func text(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: false)
    }
}

extension Value {
    /// Returns the value as a Double, accepting both JSON floats and JSON integers.
    ///
    /// MCP clients often send whole-number coordinates as JSON integers (e.g. `{"x": 100}`).
    /// `Value.doubleValue` returns nil for integer-typed JSON values, so coordinate guards
    /// that only check `.doubleValue` incorrectly treat valid integer inputs as missing params.
    /// This property tries `.doubleValue` first, then falls back to `.intValue`.
    var numericDoubleValue: Double? {
        doubleValue ?? intValue.map(Double.init)
    }
}
