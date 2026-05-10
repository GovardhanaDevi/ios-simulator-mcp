import Foundation
import MCP

let simulatorManager = SimulatorManager()
let wdaManager       = WDAManager()
let dispatcher       = ToolDispatcher(simulatorManager: simulatorManager, wdaManager: wdaManager)

let server = Server(
    name: "ios-simulator-mcp",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: ToolDefinitions.allTools)
}

await server.withMethodHandler(CallTool.self) { params in
    try await dispatcher.dispatch(params)
}

let transport = StdioTransport()
try await server.start(transport: transport)
log("[MCP] ios-simulator-mcp running on stdio")
await server.waitUntilCompleted()
