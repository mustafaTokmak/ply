import Foundation
import PlyShared

/// Agent-facing docs generated from the real action registry, so they never drift.
/// `ply docs write <repo>` writes them into docs/ and skills/; a test fails if the
/// committed copies differ from what this code generates.
public enum Docs {
    static let pitch = "Ply is a free, open-source macOS menu bar app that keeps your Mac on your iPhone's USB hotspot instead of Wi-Fi, and can combine Wi-Fi + iPhone USB (and Ethernet) so many connections at once use every link. No VPN, no account, no server: everything runs on the Mac."

    public static func llmsTxt() -> String {
        var s = """
        # Ply

        > \(pitch)

        Ply does three things:
        1. USB first: keeps iPhone USB above Wi-Fi in macOS's service order, leaves the iPhone's Wi-Fi hotspot when the cable is up, and can turn Wi-Fi off while on USB.
        2. Combine: a local proxy on 127.0.0.1:\(PlyInfo.proxyPort) that sends each new connection over the least-loaded link with internet. Many connections (browsing, multi-stream downloads, speed tests) add up; one single connection stays on one link.
        3. Diagnose: explains why USB tethering or Combine is not working, with the action that fixes each problem.

        Every action is available four ways with the same names and JSON:
        - Menu bar app: Ply.app
        - CLI: `ply <command>` (add `--json` for machine output). If `ply` is not on PATH, use `/Applications/Ply.app/Contents/Helpers/ply`.
        - MCP (stdio): `ply mcp`; tools are named `ply_<action>`
        - HTTP: `POST http://127.0.0.1:\(PlyInfo.apiPort)/v1/actions/<action>` with `Authorization: Bearer $(cat ~/Library/Application\\ Support/Ply/api-token)`. OpenAPI: `GET /openapi.json`.

        ## Actions

        """
        for a in Registry.all {
            s += "- `\(a.id.rawValue)`: \(a.summary) CLI `\(a.cli)` · MCP `\(a.mcpName)` · API `POST \(a.apiPath)`\n"
        }
        s += """

        ## Docs

        - [Full agent reference](\(PlyInfo.repoURL)/blob/main/docs/llms-full.txt)
        - [Agent skill](\(PlyInfo.repoURL)/blob/main/skills/ply/SKILL.md)
        - [OpenAPI](\(PlyInfo.repoURL)/blob/main/docs/openapi.json)
        - [README](\(PlyInfo.repoURL)#readme)

        """
        return s
    }

    public static func llmsFullTxt() -> String {
        var s = llmsTxt()
        s += """

        ## Setup

        - Install: `brew install mustafaTokmak/tap/ply` (app + `ply` on PATH), or download Ply.app from \(PlyInfo.repoURL)/releases, move it to /Applications, open it. It lives in the menu bar.
        - Helper: changing macOS's service order or proxy settings needs admin rights. Run `install_helper` once (`ply helper install`, or `sudo ply helper install` over SSH). It installs a root LaunchDaemon (`app.ply.helper`) that can only reorder services, point services' auto-proxy at `\(PlyInfo.pacURL)`, restore the old proxy settings, and enable/disable one service. It also links the CLI to /usr/local/bin/ply.
        - Engine: the app runs the engine. Without the app, `ply daemon` runs the same engine headless. CLI and MCP calls start one automatically for actions that need it (`combine_start`); read-only actions work without one.

        ## Action reference

        """
        for a in Registry.all {
            s += "### \(a.id.rawValue)\n\n\(a.summary)\n\n"
            s += "- Title in the app: \(a.title)\n- CLI: `\(a.cli)`\n- MCP tool: `\(a.mcpName)`\n- HTTP: `POST \(a.apiPath)`"
            if a.readOnly && a.params.allSatisfy({ !$0.required }) { s += " (also `GET`)" }
            s += "\n- Read-only: \(a.readOnly ? "yes" : "no")\n- Runs: \(hostText(a.host))\n"
            if a.params.isEmpty {
                s += "- Parameters: none\n"
            } else {
                s += "- Parameters:\n"
                for p in a.params { s += "  - `\(p.name)` (\(p.type.label)\(p.required ? ", required" : "")): \(p.summary)\n" }
            }
            s += "\n"
        }
        s += "## Settings\n\n"
        for f in Settings.fields { s += "- `\(f.key)` (\(f.type.label)): \(f.summary)\n" }
        s += """

        ## HTTP endpoints

        """
        for r in APIRoute.table { s += "- `\(r.method) \(r.path)`: \(r.summary)\n" }
        s += """

        Errors are JSON: `{"ok": false, "error": "...", "code": "bad_request|needs_helper|unavailable|failed", "fix": "<action>"}`. `fix` names the action that resolves the error, when there is one.

        ## Status fields (status action)

        - `summary`: one line, e.g. "Internet via iPhone USB" or "Combining Wi-Fi + iPhone USB".
        - `primary`: BSD name of the interface macOS routes through (e.g. en7).
        - `links[]`: `{bsd, name, kind: wifi|tether|ethernet, up, primary, iphoneHotspot, ipv4, router, rxBps, txBps}`.
        - `usb.state`: `not-connected` | `plugged-in-no-hotspot` | `plugged-in-idle` (macOS keeps the cable idle because "Disable unless needed" is on; fix with `prefer_usb`) | `active`.
        - `serviceOrder[]`: macOS network services in priority order, with `kind`.
        - `combine`: `{running, split, systemProxy, activeFlows, totalFlows, healthyLinks, links[{bsd, health, activeFlows, bytesIn, bytesOut, inBps, outBps}]}`.
        - `helper`: `{installed, running, version, needsUpdate}`.
        - `findings[]`: `{id, severity: ok|info|warn|error, title, detail, fix, agentPrompt}`.
        - `events[]`: what Ply did recently (newest first).

        ## Common tasks

        - "Make my Mac use the iPhone over USB": `ply diagnose --json`, then `ply prefer-usb` (install the helper first if asked), then `ply status --json` and check `primary` is the tether link.
        - "Make my internet faster with Wi-Fi + phone": plug in the iPhone with Personal Hotspot on, keep Wi-Fi on a different network, run `ply combine on`, then `ply speedtest` to compare each link alone with both together.
        - "Stop everything": `ply combine off` (restores proxy settings), or `ply quit`.

        ## Limits

        - Combine works per connection. One single TCP stream (one big download) uses one link. True single-stream bonding needs a server on the other side and is not part of Ply.
        - Combine reaches apps through macOS's proxy settings (PAC). Browsers, most apps and URLSession honor it. UDP (QUIC, games, video calls) and apps that ignore system proxies use the primary link, which is iPhone USB when USB first is on.
        - If Wi-Fi and the tether reach the internet through the same iPhone, combining adds nothing.
        - Speed tests and Combine use mobile data on the iPhone link.

        """
        return s
    }

    static func hostText(_ h: ActionHost) -> String {
        switch h {
        case .anywhere: return "anywhere, including a one-shot CLI/MCP call with no app open"
        case .engine: return "in the Ply engine (app or `ply daemon`); CLI/MCP start one if needed"
        case .app: return "only in the Ply menu bar app"
        }
    }

    public static func skillMarkdown() -> String {
        var s = """
        ---
        name: ply
        description: Control the Ply macOS app, which keeps a Mac on its iPhone's USB hotspot and combines Wi-Fi + iPhone USB for more bandwidth. Use when the user wants their Mac to use the iPhone over USB, wants faster internet from Wi-Fi plus their phone, or asks why tethering or the connection is not working.
        ---

        # Ply

        \(pitch)

        ## Tools

        Prefer the MCP server (`ply mcp`, tools `ply_<action>`). Otherwise use the CLI (`ply ... --json`). Both return JSON.

        | Action | CLI | MCP |
        | --- | --- | --- |

        """
        for a in Registry.all { s += "| \(a.title) | `\(a.cli)` | `\(a.mcpName)` |\n" }
        s += """

        ## Workflows

        ### Put the Mac on iPhone USB
        1. `ply diagnose --json`. If a finding says the iPhone is not sharing, tell the user: on the iPhone open Settings > Personal Hotspot and turn on Allow Others to Join, then keep the phone unlocked.
        2. If `helper.installed` is false, run `ply helper install`. It shows a macOS password dialog to the user; over SSH use `sudo ply helper install`. Tell the user before you do this.
        3. `ply prefer-usb`, then `ply status --json`. Done when `primary` is the link whose `kind` is `tether`.
        4. Optional: `ply settings set wifiOffWhenUSB=true` to turn Wi-Fi off whenever the cable is up.

        ### Combine Wi-Fi + iPhone for more bandwidth
        1. Check `ply status --json` shows two links with `up: true` (Wi-Fi on a normal network plus iPhone USB). If Wi-Fi is on the iPhone's own hotspot, combining adds nothing.
        2. `ply combine on` (add `--split site` if the user logs in to sites that dislike changing IPs).
        3. `ply speedtest --json` to show each link alone versus combined. Warn first: it uses mobile data (up to `speedTestMaxMB` per link per phase).
        4. To keep it on automatically: `ply settings set combineAuto=true`.
        5. To stop: `ply combine off`. It restores the proxy settings.

        ### Something is broken
        1. `ply diagnose --json`; each finding has `fix` (an action) and `agentPrompt`.
        2. iPhone plugged in but no internet: `ply repair`, then check the cable and Personal Hotspot.
        3. Web pages fail while combining: `ply combine off` restores normal networking at once. `ply restore-proxies` is always safe.

        ## Rules
        - Ask before `install_helper`, `uninstall_helper`, `set_wifi_power` and `speed_test` (password prompt, losing Wi-Fi, mobile data).
        - Combine helps many connections at once, not one single download. Say so when you report speed results.
        - Never edit macOS proxy or network settings directly; use Ply so it can restore them.

        """
        return s
    }

    public static func actionsJSON() -> JSONValue {
        .object([
            "actions": .array(Registry.all.map { a in
                .object([
                    "id": .string(a.id.rawValue), "title": .string(a.title), "summary": .string(a.summary),
                    "readOnly": .bool(a.readOnly), "runs": .string(a.host.rawValue), "cli": .string(a.cli),
                    "mcp": .string(a.mcpName), "api": .string("POST " + a.apiPath), "inputSchema": a.inputSchema,
                ])
            }),
        ])
    }

    /// OpenAPI 3.1 description of the local HTTP API, generated from the registry.
    public static func openAPI() -> JSONValue {
        let errorSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ok": .object(["type": .string("boolean")]),
                "error": .object(["type": .string("string")]),
                "code": .object(["type": .string("string"), "enum": .array(["bad_request", "needs_helper", "unavailable", "failed"].map { .string($0) })]),
                "fix": .object(["type": .string("string"), "description": .string("The action that resolves the error, when there is one.")]),
            ]),
        ])
        let json: (JSONValue) -> JSONValue = { .object(["application/json": .object(["schema": $0])]) }
        let errors: [String: JSONValue] = ["400": .object(["description": .string("Bad parameters"), "content": json(.object(["$ref": .string("#/components/schemas/Error")]))]),
                                           "401": .object(["description": .string("Missing or wrong token")]),
                                           "default": .object(["description": .string("Error"), "content": json(.object(["$ref": .string("#/components/schemas/Error")]))])]
        var paths: [String: JSONValue] = [:]
        for r in APIRoute.table where r.method == "GET" {
            let open = APIRoute.resolve(method: "GET", path: r.path).map { !$0.needsAuth } ?? false
            var op: [String: JSONValue] = ["summary": .string(r.summary), "responses": .object(["200": .object(["description": .string("OK")])])]
            if open { op["security"] = .array([]) }
            paths[r.path] = .object(["get": .object(op)])
        }
        for a in Registry.all {
            var responses = errors
            responses["200"] = .object(["description": .string("Result as JSON"), "content": json(.object(["type": .string("object")]))])
            paths[a.apiPath] = .object(["post": .object([
                "operationId": .string(a.id.rawValue), "summary": .string(a.title), "description": .string(a.summary),
                "x-cli": .string(a.cli), "x-mcp-tool": .string(a.mcpName), "x-read-only": .bool(a.readOnly),
                "requestBody": .object(["required": .bool(false), "content": json(a.inputSchema)]),
                "responses": .object(responses),
            ])])
        }
        return .object([
            "openapi": .string("3.1.0"),
            "info": .object(["title": .string("Ply local API"), "version": .string(PlyInfo.version), "description": .string(pitch + " The API listens only on 127.0.0.1. Send `Authorization: Bearer <token>`; the token is in ~/Library/Application Support/Ply/api-token.")]),
            "servers": .array([.object(["url": .string("http://127.0.0.1:\(PlyInfo.apiPort)")])]),
            "security": .array([.object(["bearer": .array([])])]),
            "components": .object([
                "securitySchemes": .object(["bearer": .object(["type": .string("http"), "scheme": .string("bearer")])]),
                "schemas": .object(["Error": errorSchema]),
            ]),
            "paths": .object(paths),
        ])
    }

    static let readmeStart = "<!-- agent-reference:start (generated by `ply docs write .`, do not edit) -->"
    static let readmeEnd = "<!-- agent-reference:end -->"

    /// The action table in README.md, between the agent-reference markers.
    public static func readmeAgentReference() -> String {
        var s = readmeStart + "\n\n| Action | What it does | CLI | MCP tool | HTTP |\n| --- | --- | --- | --- | --- |\n"
        for a in Registry.all {
            let summary = a.summary.replacingOccurrences(of: "|", with: "\\|")
            let cli = a.cli.replacingOccurrences(of: "|", with: "\\|")
            s += "| \(a.title) | \(summary) | `\(cli)` | `\(a.mcpName)` | `POST \(a.apiPath)` |\n"
        }
        return s + "\n" + readmeEnd
    }

    /// README.md with its agent-reference section replaced by the generated one.
    public static func readme(updating text: String) -> String? {
        guard let start = text.range(of: readmeStart), let end = text.range(of: readmeEnd), start.lowerBound < end.lowerBound else { return nil }
        return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: readmeAgentReference())
    }

    /// Writes the generated docs into a checkout: llms.txt, llms-full.txt, openapi.json, SKILL.md
    /// and the action table in README.md.
    public static func write(repo: URL) throws -> [String] {
        let openapi = openAPI().pretty() + "\n"
        var files: [(String, String)] = [
            ("docs/llms.txt", llmsTxt()),
            ("docs/llms-full.txt", llmsFullTxt()),
            ("docs/openapi.json", openapi),
            ("skills/ply/SKILL.md", skillMarkdown()),
            ("site/llms.txt", llmsTxt()),
            ("site/llms-full.txt", llmsFullTxt()),
            ("site/openapi.json", openapi),
        ]
        let readmeURL = repo.appendingPathComponent("README.md")
        if let current = try? String(contentsOf: readmeURL, encoding: .utf8), let updated = readme(updating: current) {
            files.append(("README.md", updated))
        }
        for (path, text) in files {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return files.map(\.0)
    }
}

public enum StatusMarkdown {
    static func rate(_ bps: Double) -> String {
        let mbps = bps * 8 / 1_000_000
        return mbps >= 10 ? String(format: "%.0f Mb/s", mbps) : String(format: "%.1f Mb/s", mbps)
    }

    public static func render(_ r: StatusReport) -> String {
        var s = "# Ply status\n\n**\(r.summary)** (engine: \(r.engine), \(ISO8601DateFormatter().string(from: r.updatedAt)))\n\n"
        s += "| Link | Device | State | Address | Down | Up |\n| --- | --- | --- | --- | --- | --- |\n"
        for l in r.links {
            s += "| \(l.name)\(l.primary ? " (primary)" : "") | \(l.bsd) | \(l.up ? "connected" : "not connected") | \(l.ipv4.first ?? "-") | \(rate(l.rxBps)) | \(rate(l.txBps)) |\n"
        }
        s += "\n**Combine:** \(r.combine.running ? "on, \(r.combine.activeFlows) active connections, \(r.combine.healthyLinks) healthy links, split by \(r.combine.split.rawValue)" : "off")\n\n"
        s += "**Helper:** \(r.helper.installed ? (r.helper.running ? "installed (\(r.helper.version ?? "?"))" : "installed, not answering") : "not installed")\n\n"
        s += "**Service order:** " + r.serviceOrder.filter(\.enabled).map(\.name).joined(separator: " > ") + "\n\n"
        if let t = r.lastSpeedTest { s += "**Last speed test:** \(t.headline)\n\n" }
        s += "## Findings\n\n"
        for f in r.findings {
            s += "- **\(f.title)** (\(f.severity.rawValue)). \(f.detail)\(f.fix.map { " Fix: `\(Registry.spec($0).cli)`." } ?? "")\n"
        }
        if !r.events.isEmpty {
            s += "\n## Recent events\n\n"
            for e in r.events.prefix(10) { s += "- \(ISO8601DateFormatter().string(from: e.at)): \(e.message)\n" }
        }
        return s
    }

    public static func plain(_ r: StatusReport) -> String {
        var s = "\(r.summary)\n"
        for l in r.links {
            let mark = l.primary ? "*" : " "
            s += " \(mark) \(l.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(l.bsd.padding(toLength: 6, withPad: " ", startingAt: 0)) \(l.up ? (l.ipv4.first ?? "up") : "not connected")"
            if l.up { s += "  ↓ \(rate(l.rxBps))  ↑ \(rate(l.txBps))" }
            s += "\n"
        }
        s += "Combine: \(r.combine.running ? "on (\(r.combine.activeFlows) connections, \(r.combine.healthyLinks) healthy links)" : "off")   Helper: \(r.helper.installed ? "installed" : "not installed")\n"
        let issues = r.findings.filter { $0.severity == .warn || $0.severity == .error }
        for f in issues { s += "! \(f.title)\(f.fix.map { " -> \(Registry.spec($0).cli)" } ?? "")\n" }
        return s
    }
}
