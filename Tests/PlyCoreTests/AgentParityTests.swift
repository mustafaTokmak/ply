import XCTest
@testable import PlyCore

/// Agent-first rule: every action a person can take in the app must also be an
/// HTTP endpoint and an MCP tool, and the agent docs must match the code.
final class AgentParityTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let appSources = repo.appendingPathComponent("Sources/PlyApp")

    func appFiles() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.appSources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "no app sources found at \(Self.appSources.path)")
        return try names.map { ($0, try String(contentsOf: Self.appSources.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testEveryActionHasSpecAPIAndMCPTool() {
        let tools = Set(MCPServer.toolList().compactMap { $0["name"]?.stringValue })
        let apiPaths = Set(APIRoute.table.filter { $0.method == "POST" }.map(\.path))
        for id in ActionID.allCases {
            let spec = Registry.spec(id)
            XCTAssertEqual(APIRoute.resolve(method: "POST", path: spec.apiPath), .action(id), "no API route for \(id)")
            XCTAssertTrue(apiPaths.contains(spec.apiPath), "API table misses \(id)")
            XCTAssertTrue(tools.contains(spec.mcpName), "no MCP tool for \(id)")
            XCTAssertFalse(spec.cli.isEmpty, "no CLI form documented for \(id)")
            XCTAssertFalse(spec.summary.isEmpty)
        }
        XCTAssertEqual(Registry.all.count, ActionID.allCases.count, "duplicate or missing specs")
    }

    /// Fails the build if an app file creates an interactive control outside ActionControls.swift,
    /// i.e. a control that might not go through the action registry.
    func testUIControlsOnlyRunRegistryActions() throws {
        let control = try NSRegularExpression(pattern: #"(?<![A-Za-z])(Button|Toggle|Picker|Menu|Link|TextField|SecureField|Slider|Stepper|NSMenuItem|NSButton)\s*[({]|\.onTapGesture|\.onSubmit|\.contextMenu"#)
        for (name, text) in try appFiles() where name != "ActionControls.swift" {
            let hits = control.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
            XCTAssertTrue(hits.isEmpty, "\(name) creates \(hits) directly. Use ActionButton/ActionToggle/SettingToggle/SettingPicker so the control runs a registry action that also exists as an API endpoint and MCP tool.")
        }
        let controls = try String(contentsOf: Self.appSources.appendingPathComponent("ActionControls.swift"), encoding: .utf8)
        let made = control.numberOfMatches(in: controls, range: NSRange(controls.startIndex..., in: controls))
        let runs = controls.components(separatedBy: "model.run(").count - 1
        XCTAssertGreaterThan(made, 0)
        XCTAssertGreaterThanOrEqual(runs, made, "every control in ActionControls.swift must call model.run(...)")
    }

    /// Every action and setting the UI references exists in the registry.
    func testUIReferencesKnownActionsAndSettings() throws {
        let actionPattern = try NSRegularExpression(pattern: #"(?:action|on|off):\s*\.([A-Za-z]+)"#)
        let settingPattern = try NSRegularExpression(pattern: #"key:\s*"([A-Za-z]+)""#)
        let caseNames = Set(ActionID.allCases.map { "\($0)" })
        let settingKeys = Set(Settings.fields.map(\.key))
        var seen = Set<String>()
        for (name, text) in try appFiles() {
            let range = NSRange(text.startIndex..., in: text)
            for m in actionPattern.matches(in: text, range: range) {
                let n = String(text[Range(m.range(at: 1), in: text)!])
                guard !["none", "copy", "open", "switch", "small", "mini", "regular", "segmented", "borderless", "accessory"].contains(n) else { continue }
                XCTAssertTrue(caseNames.contains(n), "\(name) references unknown action .\(n)")
                seen.insert(n)
            }
            for m in settingPattern.matches(in: text, range: range) {
                let k = String(text[Range(m.range(at: 1), in: text)!])
                XCTAssertTrue(settingKeys.contains(k), "\(name) references unknown setting \(k)")
            }
        }
        XCTAssertTrue(seen.contains("combineStart") && seen.contains("speedTest"), "UI scan found too little; pattern broken?")
    }

    func testCommittedAgentDocsMatchGenerated() throws {
        let expected: [(String, String)] = [
            ("docs/llms.txt", Docs.llmsTxt()),
            ("docs/llms-full.txt", Docs.llmsFullTxt()),
            ("skills/ply/SKILL.md", Docs.skillMarkdown()),
            ("site/llms.txt", Docs.llmsTxt()),
            ("site/llms-full.txt", Docs.llmsFullTxt()),
            ("docs/openapi.json", Docs.openAPI().pretty() + "\n"),
            ("site/openapi.json", Docs.openAPI().pretty() + "\n"),
        ]
        for (path, text) in expected {
            let committed = try? String(contentsOf: Self.repo.appendingPathComponent(path), encoding: .utf8)
            XCTAssertEqual(committed, text, "\(path) is out of date. Run `swift run ply docs write .` and commit.")
        }
    }

    func testREADMEAgentReferenceMatchesGenerated() throws {
        let readme = try String(contentsOf: Self.repo.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains(Docs.readmeAgentReference()), "README.md's agent reference is out of date. Run `swift run ply docs write .` and commit.")
    }

    func testOpenAPICoversEveryAction() {
        let paths = Docs.openAPI()["paths"]?.objectValue ?? [:]
        for a in Registry.all {
            XCTAssertEqual(paths[a.apiPath]?["post"]?["operationId"]?.stringValue, a.id.rawValue, "openapi.json misses \(a.id)")
        }
    }

    func testDocsMentionEveryAction() {
        let llms = Docs.llmsTxt(), full = Docs.llmsFullTxt(), skill = Docs.skillMarkdown()
        for spec in Registry.all {
            XCTAssertTrue(llms.contains(spec.mcpName), "llms.txt misses \(spec.id)")
            XCTAssertTrue(full.contains("### \(spec.id.rawValue)"), "llms-full.txt misses \(spec.id)")
            XCTAssertTrue(skill.contains(spec.mcpName), "SKILL.md misses \(spec.id)")
        }
        for f in Settings.fields { XCTAssertTrue(full.contains("`\(f.key)`"), "llms-full.txt misses setting \(f.key)") }
    }

    func testMCPListAndCall() async throws {
        let list = await MCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")])) { _, _ in .null }
        XCTAssertEqual(list?["result"]?["tools"]?.arrayValue?.count, ActionID.allCases.count)

        let call = await MCPServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
            "params": .object(["name": .string("ply_about"), "arguments": .object([:])]),
        ])) { id, _ in .object(["called": .string(id.rawValue)]) }
        XCTAssertEqual(call?["result"]?["structuredContent"]?["called"]?.stringValue, "about")
        XCTAssertEqual(call?["result"]?["isError"]?.boolValue, false)

        let bad = await MCPServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/call"),
            "params": .object(["name": .string("ply_nope")]),
        ])) { _, _ in .null }
        XCTAssertNotNil(bad?["error"])

        let note = await MCPServer.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])) { _, _ in .null }
        XCTAssertNil(note)

        let failing = await MCPServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(4), "method": .string("tools/call"),
            "params": .object(["name": .string("ply_prefer_usb")]),
        ])) { _, _ in throw PlyError.needsHelper("needs helper") }
        XCTAssertEqual(failing?["result"]?["isError"]?.boolValue, true)
        XCTAssertEqual(failing?["result"]?["structuredContent"]?["fix"]?.stringValue, "install_helper")
    }

    func testParamValidation() {
        XCTAssertNoThrow(try Registry.validate(.combineStart, ["split": .string("site")]))
        XCTAssertThrowsError(try Registry.validate(.combineStart, ["split": .string("fast")]))
        XCTAssertThrowsError(try Registry.validate(.status, ["x": .bool(true)]))
        XCTAssertThrowsError(try Registry.validate(.setWiFiPower, [:]))
        XCTAssertThrowsError(try Registry.validate(.speedTest, ["seconds": .string("5")]))
    }
}
