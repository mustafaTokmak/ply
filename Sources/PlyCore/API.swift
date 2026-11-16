import Foundation
import Network
import PlyShared

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var headers: [String: String]
    public var body: Data

    /// Parses one request. Returns nil while incomplete; throws on malformed or oversized input.
    public static func parse(_ data: Data, maxBody: Int = 1 << 20) throws -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 32 * 1024 { throw PlyError.badRequest("headers too large") }
            return nil
        }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ").map(String.init)
        guard first.count >= 2 else { throw PlyError.badRequest("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { throw PlyError.badRequest("body too large") }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: length))
        let target = first[1]
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return HTTPRequest(method: first[0].uppercased(), path: parts.first ?? "/", query: parts.count > 1 ? parts[1] : nil, headers: headers, body: body)
    }
}

public enum APIRoute: Equatable, Sendable {
    case index, health, llms, llmsFull, skill, openapi, pac, status, statusMarkdown, actions
    case action(ActionID)

    public var needsAuth: Bool {
        switch self {
        case .health, .llms, .llmsFull, .skill, .openapi, .pac, .index: return false
        default: return true
        }
    }

    public static func resolve(method: String, path: String) -> APIRoute? {
        switch (method, path) {
        case ("GET", "/"): return .index
        case ("GET", "/health"): return .health
        case ("GET", "/llms.txt"): return .llms
        case ("GET", "/llms-full.txt"): return .llmsFull
        case ("GET", "/SKILL.md"): return .skill
        case ("GET", "/openapi.json"): return .openapi
        case ("GET", "/proxy.pac"): return .pac
        case ("GET", "/v1/status"): return .status
        case ("GET", "/v1/status.md"): return .statusMarkdown
        case ("GET", "/v1/actions"): return .actions
        default: break
        }
        let prefix = "/v1/actions/"
        if path.hasPrefix(prefix), let id = ActionID(rawValue: String(path.dropFirst(prefix.count))) {
            if method == "POST" { return .action(id) }
            if method == "GET" && Registry.spec(id).readOnly && Registry.spec(id).params.allSatisfy({ !$0.required }) { return .action(id) }
        }
        return nil
    }

    /// Every endpoint, for docs and the parity test.
    public static var table: [(method: String, path: String, summary: String)] {
        var t: [(String, String, String)] = [
            ("GET", "/health", "Liveness: {app, version, engine}. No token needed."),
            ("GET", "/llms.txt", "Agent overview of Ply. No token needed."),
            ("GET", "/llms-full.txt", "Full agent reference. No token needed."),
            ("GET", "/SKILL.md", "Agent skill for Ply's main workflows. No token needed."),
            ("GET", "/openapi.json", "OpenAPI 3.1 description of this API. No token needed."),
            ("GET", "/proxy.pac", "Proxy auto-config used by Combine. No token needed."),
            ("GET", "/v1/status", "Same as POST /v1/actions/status."),
            ("GET", "/v1/status.md", "Status as Markdown."),
            ("GET", "/v1/actions", "Every action with its JSON input schema."),
        ]
        for s in Registry.all { t.append(("POST", s.apiPath, s.summary)) }
        return t
    }
}

/// Local HTTP API on 127.0.0.1. Everything except docs, health and the PAC file needs
/// `Authorization: Bearer <token>` (token file: ~/Library/Application Support/Ply/api-token),
/// and the Host header must be 127.0.0.1 or localhost (blocks DNS rebinding).
public final class APIServer: @unchecked Sendable {
    let engine: Engine
    let port: UInt16
    let token: String
    private var listener: NWListener?
    private let q = DispatchQueue(label: "app.ply.api")

    public init(engine: Engine, port: UInt16 = PlyInfo.apiPort) {
        self.engine = engine
        self.port = port
        self.token = Paths.ensureToken()
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { st in
            switch st {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: q)
        if ready.wait(timeout: .now() + 3) == .timedOut || failure != nil {
            l.cancel()
            throw PlyError.failed("Cannot listen on 127.0.0.1:\(port)\(failure.map { ": \($0)" } ?? ""). Is Ply already running?")
        }
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { c.cancel(); return }
                if let data { buffer.append(data) }
                do {
                    if let req = try HTTPRequest.parse(buffer) {
                        Task { await self.respond(c, req) }
                        return
                    }
                } catch {
                    self.send(c, status: 400, json: PlyError.wrap(error).json)
                    return
                }
                if isComplete || error != nil { c.cancel() } else { read() }
            }
        }
        read()
        q.asyncAfter(deadline: .now() + 30) { if c.state != .cancelled && buffer.isEmpty { c.cancel() } }
    }

    private func respond(_ c: NWConnection, _ req: HTTPRequest) async {
        let host = (req.headers["host"] ?? "").lowercased()
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost"]
        guard allowedHosts.contains(host) else {
            send(c, status: 403, json: PlyError.badRequest("Host header must be 127.0.0.1:\(port)").json)
            return
        }
        guard let route = APIRoute.resolve(method: req.method, path: req.path) else {
            send(c, status: 404, json: PlyError.badRequest("No such endpoint \(req.method) \(req.path). See GET /llms.txt or GET /v1/actions.").json)
            return
        }
        if route.needsAuth && req.headers["authorization"] != "Bearer \(token)" {
            send(c, status: 401, json: PlyError.badRequest("Missing or wrong token. Send Authorization: Bearer <contents of ~/Library/Application Support/Ply/api-token>.").json)
            return
        }
        switch route {
        case .index:
            send(c, status: 200, json: .object([
                "app": .string(PlyInfo.name), "version": .string(PlyInfo.version),
                "docs": .array(["/llms.txt", "/llms-full.txt", "/SKILL.md", "/openapi.json"].map { .string($0) }),
                "endpoints": .array(APIRoute.table.map { .string("\($0.method) \($0.path)") }),
            ]))
        case .health:
            send(c, status: 200, json: .object(["app": .string(PlyInfo.name), "version": .string(PlyInfo.version), "engine": .string(engine.mode.rawValue)]))
        case .llms:
            send(c, status: 200, text: Docs.llmsTxt(), type: "text/plain; charset=utf-8")
        case .llmsFull:
            send(c, status: 200, text: Docs.llmsFullTxt(), type: "text/plain; charset=utf-8")
        case .skill:
            send(c, status: 200, text: Docs.skillMarkdown(), type: "text/markdown; charset=utf-8")
        case .openapi:
            send(c, status: 200, json: Docs.openAPI())
        case .pac:
            send(c, status: 200, text: PAC.script(proxyPort: PlyInfo.proxyPort), type: "application/x-ns-proxy-autoconfig")
        case .status:
            await runAction(c, .status, [:])
        case .statusMarkdown:
            do {
                let r = try await engine.perform(.status).decode(as: StatusReport.self)
                send(c, status: 200, text: StatusMarkdown.render(r), type: "text/markdown; charset=utf-8")
            } catch {
                let e = PlyError.wrap(error)
                send(c, status: e.httpStatus, json: e.json)
            }
        case .actions:
            send(c, status: 200, json: Docs.actionsJSON())
        case .action(let id):
            var params: Params = [:]
            if !req.body.isEmpty {
                guard let obj = (try? JSONValue.parse(req.body))?.objectValue else {
                    send(c, status: 400, json: PlyError.badRequest("Body must be a JSON object of parameters.").json)
                    return
                }
                params = obj
            }
            await runAction(c, id, params)
        }
    }

    private func runAction(_ c: NWConnection, _ id: ActionID, _ params: Params) async {
        do {
            let result = try await engine.perform(id, params)
            send(c, status: 200, json: result)
        } catch {
            let e = PlyError.wrap(error)
            send(c, status: e.httpStatus, json: e.json)
        }
    }

    private func send(_ c: NWConnection, status: Int, json: JSONValue) {
        send(c, status: status, text: json.pretty() + "\n", type: "application/json; charset=utf-8")
    }

    private func send(_ c: NWConnection, status: Int, text: String, type: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Client for a running engine's API.
public struct APIClient: Sendable {
    public let port: UInt16
    public init(port: UInt16 = PlyInfo.apiPort) { self.port = port }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 120
        return URLSession(configuration: cfg)
    }()

    public struct Health: Codable, Sendable { public var app: String; public var version: String; public var engine: String }

    public func health() async -> Health? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await Self.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    public func perform(_ id: ActionID, _ params: Params) async throws -> JSONValue {
        guard let token = Paths.readToken() else { throw PlyError.unavailable("No API token found at \(Paths.tokenFile.path).") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/actions/\(id.rawValue)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(JSONValue.object(params).compact().utf8)
        let (data, resp) = try await Self.session.data(for: req)
        let value = (try? JSONValue.parse(data)) ?? .object(["error": .string(String(decoding: data, as: UTF8.self))])
        guard let http = resp as? HTTPURLResponse else { throw PlyError.failed("No HTTP response") }
        if http.statusCode != 200 {
            let msg = value["error"]?.stringValue ?? "HTTP \(http.statusCode)"
            switch value["code"]?.stringValue {
            case "bad_request": throw PlyError.badRequest(msg)
            case "needs_helper": throw PlyError.needsHelper(msg)
            case "unavailable": throw PlyError.unavailable(msg)
            default: throw PlyError.failed(msg)
            }
        }
        return value
    }
}

/// Runs an action from a client (CLI or MCP): through the running engine if there is one,
/// otherwise in-process for actions that do not need one, otherwise after starting one.
public enum Runner {
    public static func run(_ id: ActionID, _ params: Params = [:]) async throws -> JSONValue {
        let client = APIClient()
        if await client.health() != nil {
            return try await client.perform(id, params)
        }
        let spec = Registry.spec(id)
        switch spec.host {
        case .anywhere:
            return try await Engine(mode: .passive).perform(id, params)
        case .engine, .app:
            try await EngineLauncher.ensureRunning(needApp: spec.host == .app)
            return try await client.perform(id, params)
        }
    }
}

public enum EngineLauncher {
    /// Opens Ply.app if installed (or required), else starts `ply daemon` in the background.
    public static func ensureRunning(needApp: Bool) async throws {
        let client = APIClient()
        if await client.health() != nil { return }
        if openApp() {
            for _ in 0..<40 {
                if await client.health() != nil { return }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if needApp { throw PlyError.unavailable("This needs the Ply app. Install Ply.app in /Applications and open it.") }
        let cli = HelperInstaller.cliBinary() ?? HelperInstaller.executableURL
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup \(HelperInstaller.shellQuote(cli.path)) daemon >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
        for _ in 0..<40 {
            if await client.health() != nil { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw PlyError.unavailable("Started `ply daemon` but it did not answer on 127.0.0.1:\(PlyInfo.apiPort).")
    }

    static func openApp() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", PlyInfo.bundleID]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
