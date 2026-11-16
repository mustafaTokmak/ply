import Foundation
import PlyShared

/// MCP server over stdio (newline-delimited JSON-RPC 2.0). Tools are generated from the
/// action registry, so every UI action is also an MCP tool named `ply_<action>`.
public enum MCPServer {
    public static let defaultProtocolVersion = "2025-06-18"

    public static func toolList() -> [JSONValue] {
        Registry.all.map { spec in
            .object([
                "name": .string(spec.mcpName),
                "title": .string(spec.title),
                "description": .string(spec.summary + " CLI equivalent: `\(spec.cli)`."),
                "inputSchema": spec.inputSchema,
                "annotations": .object([
                    "readOnlyHint": .bool(spec.readOnly),
                    "destructiveHint": .bool(false),
                    "idempotentHint": .bool(spec.readOnly || [.preferUSB, .combineStop, .restoreProxies, .getSettings, .updateSettings, .setWiFiPower].contains(spec.id)),
                    "openWorldHint": .bool(spec.id == .speedTest),
                ]),
            ])
        }
    }

    static let instructions = """
    Ply keeps a Mac on its iPhone's USB hotspot and can combine Wi-Fi + iPhone USB (and Ethernet) for more total bandwidth. \
    Start with ply_status or ply_diagnose. Each finding names the tool that fixes it. ply_prefer_usb and system-proxy Combine need the helper (ply_install_helper, asks the user for an admin password once). \
    ply_speed_test uses mobile data. Combine speeds up many parallel connections (browsing, multi-stream downloads), not one single download.
    """

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public static func handle(_ msg: JSONValue, call: (ActionID, Params) async throws -> JSONValue) async -> JSONValue? {
        guard let method = msg["method"]?.stringValue else {
            return nil
        }
        let id = msg["id"]
        let isNotification = id == nil
        func result(_ r: JSONValue) -> JSONValue? {
            isNotification ? nil : .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": r])
        }
        func error(_ code: Int, _ message: String) -> JSONValue? {
            isNotification ? nil : .object(["jsonrpc": .string("2.0"), "id": id ?? .null,
                                            "error": .object(["code": .number(Double(code)), "message": .string(message)])])
        }
        switch method {
        case "initialize":
            let version = msg["params"]?["protocolVersion"]?.stringValue ?? defaultProtocolVersion
            return result(.object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("ply"), "title": .string("Ply"), "version": .string(PlyInfo.version)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return result(.object([:]))
        case "tools/list":
            return result(.object(["tools": .array(toolList())]))
        case "tools/call":
            guard let name = msg["params"]?["name"]?.stringValue, let action = Registry.action(mcpName: name) else {
                return error(-32602, "Unknown tool. Call tools/list for the available tools.")
            }
            let args = msg["params"]?["arguments"]?.objectValue ?? [:]
            do {
                let value = try await call(action, args)
                var r: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(value.pretty())])]), "isError": .bool(false)]
                if case .object = value { r["structuredContent"] = value }
                return result(.object(r))
            } catch {
                let e = PlyError.wrap(error)
                return result(.object([
                    "content": .array([.object(["type": .string("text"), "text": .string(e.json.pretty())])]),
                    "structuredContent": e.json,
                    "isError": .bool(true),
                ]))
            }
        default:
            if method.hasPrefix("notifications/") { return nil }
            return error(-32601, "Method not found: \(method)")
        }
    }

    /// Blocking stdio loop used by `ply mcp`.
    public static func runStdio() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let msg = try? JSONValue.parse(Data(trimmed.utf8)) else {
                write(.object(["jsonrpc": .string("2.0"), "id": .null, "error": .object(["code": .number(-32700), "message": .string("Parse error")])]))
                continue
            }
            let sem = DispatchSemaphore(value: 0)
            var reply: JSONValue?
            Task {
                reply = await handle(msg) { id, params in try await Runner.run(id, params) }
                sem.signal()
            }
            sem.wait()
            if let reply { write(reply) }
        }
        exit(0)
    }

    static func write(_ v: JSONValue) {
        FileHandle.standardOutput.write(Data((v.compact() + "\n").utf8))
    }
}
