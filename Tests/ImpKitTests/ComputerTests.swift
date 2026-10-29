import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// Hands back a picture from one tool and plain text from the other.
private struct PictureTools: ToolProvider {
    func tools() async -> [ToolSpec] { [ToolSpec(name: "echo", description: "Echo"), ToolSpec(name: "look", description: "Look")] }
    func call(_ name: String, arguments: String) async throws -> String { "text \(name)" }
    func run(_ name: String, arguments: String) async throws -> ToolOutput {
        name == "look" ? ToolOutput("saw it", images: [EncodedImage(data: Data([1, 2]), mimeType: "image/png")])
                       : ToolOutput(try await call(name, arguments: arguments))
    }
}

/// Part of BrainTests (same serialized suite): they share the stubbed network queue.
extension BrainTests {
    private func pictureAgent(_ replies: [String]) throws -> Agent {
        StubProtocol.lock.withLock { StubProtocol.queue = replies }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = try OpenAIClient(baseURL: "https://example.test/v1", apiKey: "k", session: URLSession(configuration: config))
        return Agent(client: client, model: "m", tools: PictureTools(), maxSteps: 8)
    }

    private func toolCalls(_ names: [String]) -> String {
        let items = names.enumerated().map {
            #"{"id":"c\#($0.offset)","type":"function","function":{"name":"\#($0.element)","arguments":"{}"}}"#
        }.joined(separator: ",")
        return #"{"choices":[{"message":{"content":null,"tool_calls":[\#(items)]}}]}"#
    }
    private var done: String { #"{"choices":[{"message":{"content":"done"}}]}"# }

    @Test func picturesFollowAllToolResultsAsOneMessage() async throws {
        let a = try pictureAgent([toolCalls(["look", "echo", "look"]), done])
        let (_, transcript) = try await a.run([.user("go")])
        #expect(transcript.map(\.role) == ["user", "assistant", "tool", "tool", "tool", "user", "assistant"])
        let pictures = transcript[5]
        #expect(pictures.attachment == true && pictures.images?.count == 2)
        #expect(pictures.content?.contains("look") == true)
        #expect(transcript[2].content == "saw it" && transcript[3].content == "text echo")
    }

    @Test func noPicturesNoExtraMessage() async throws {
        let a = try pictureAgent([toolCalls(["echo"]), done])
        let (_, transcript) = try await a.run([.user("go")])
        #expect(transcript.map(\.role) == ["user", "assistant", "tool", "assistant"])
    }

    @Test func attachmentIsNotSentAsAFlag() {
        let m = ChatMessage.attachment([EncodedImage(data: Data([1]), mimeType: "image/png")], from: ["computer_observe", "computer_observe"])
        #expect(m.json["attachment"] == nil)
        #expect(m.content?.hasPrefix("Screenshot from computer_observe.") == true)
        #expect((m.json["content"] as? [[String: Any]])?.count == 2)
    }

    @Test func memoryDropsAttachmentsAndKeepsExchangesWhole() {
        let picture = EncodedImage(data: Data([1]), mimeType: "image/png")
        let call = ToolCall(id: "c", name: "computer_observe", arguments: "{}")
        let exchange: [ChatMessage] = [.user("open it"), .assistant(nil, toolCalls: [call]), .tool(id: "c", content: "ok"),
                                       .attachment([picture], from: ["computer_observe"]), .assistant("done")]
        #expect(ChatMemory.exchanges(in: exchange).count == 1)
        var m = ChatMemory()
        m.remember(exchange)
        #expect(m.messages.map(\.role) == ["user", "assistant", "tool", "assistant"])
        #expect(m.messages.allSatisfy { $0.attachment != true && $0.images == nil })
        #expect(!Recap.transcript(ChatMemory(messages: exchange)).contains("Screenshot"))
        let back = try? JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(exchange[3]))
        #expect(back == exchange[3])
    }

    @Test func toolSetForwardsRun() async throws {
        let set = ToolSet([FakeTools(), PictureTools()])
        let out = try await set.run("look", arguments: "{}")
        #expect(out.text == "saw it" && out.images.count == 1)
        #expect(try await set.call("look", arguments: "{}") == "saw it")
        #expect(try await set.run("echo", arguments: "{}") == ToolOutput("got {}"))
        await #expect(throws: MCPError.self) { try await set.run("nope", arguments: "{}") }
    }
}

@Suite struct ComputerToolSpecTests {
    @Test func specsNameThreeToolsInTheComputerGroup() {
        let specs = ComputerTools.specs()
        #expect(specs.map(\.name) == [ComputerTools.observe, ComputerTools.act, ComputerTools.verify])
        for s in specs {
            #expect(ToolSet.functionName(s.name) == s.name)
            #expect(OwnTools.group(of: s.name) == .computer)
            #expect(s.inputSchema["type"]?.string == "object" && !s.description.isEmpty)
        }
        let actions = specs[1].inputSchema["properties"]?["action"]?["enum"]?.array?.compactMap(\.string) ?? []
        #expect(Set(actions) == ["click", "double_click", "right_click", "press", "focus", "type", "set_value", "key", "scroll", "drag", "select", "hover"])
        #expect(specs[1].inputSchema["required"] == ["action"] && specs[2].inputSchema["required"] == ["condition"])
    }

    @Test func ownToolsDoNotIncludeThem() {
        let names = OwnTools.specs(Set(ImpToolGroup.allCases), animations: ["yes"], imps: ["Pip"], browser: true).map(\.name)
        #expect(!names.contains(where: ComputerTools.isComputerTool))
    }

    @Test func computerControlIsOptIn() throws {
        var p = ImpProfile.imp
        #expect(!p.uses(.computer) && !p.ownTools.contains(.computer) && p.uses(.body))
        p.setUses(.computer, true)
        #expect(p.uses(.computer) && p.ownTools.contains(.computer))
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p))
        #expect(back.uses(.computer) && back == p)
        p.setUses(.setup, false)
        #expect(p.uses(.computer) && !p.uses(.setup))
        p.setUses(.computer, false); p.setUses(.setup, true)
        #expect(p == ImpProfile.imp)
    }

    @Test func permissionErrorNamesWhatIsMissing() {
        #expect(ComputerTools.permissionError(screen: false, accessibility: false) == nil)
        let both = ComputerTools.permissionError(screen: true, accessibility: true) ?? ""
        #expect(both.hasPrefix("Error:") && both.contains("Screen & System Audio Recording") && both.contains("Accessibility (Device Control & Data Access)"))
        #expect(ComputerTools.permissionError(screen: true, accessibility: false)?.contains("Accessibility") == false)
    }
}

@Suite struct ComputerActionTests {
    private func parse(_ json: String) throws -> ComputerAction { try ComputerAction(arguments: JSONValue(jsonString: json)) }

    @Test func parsesTargets() throws {
        #expect(try parse(#"{"action":"click","target":"e12"}"#).target == .element("e12"))
        #expect(try parse(#"{"action":"click","target":"E7"}"#).target == .element("e7"))
        #expect(try parse(#"{"action":"click","target":"Save"}"#).target == .text("Save"))
        #expect(try parse(#"{"action":"click","target":"120, 340.5"}"#).target == .point(CGPoint(x: 120, y: 340.5)))
        #expect(try parse(#"{"action":"click","x":10,"y":"20"}"#).target == .point(CGPoint(x: 10, y: 20)))
        #expect(try parse(#"{"action":"click","target":{"x":1,"y":2}}"#).target == .point(CGPoint(x: 1, y: 2)))
        #expect(try parse(#"{"action":"click","target":"e3","x":1,"y":2}"#).target == .element("e3"), "an id beats coordinates")
    }

    @Test func validatesPerAction() throws {
        for bad in [#"{}"#, #"{"action":"fly"}"#, #"{"action":"click"}"#, #"{"action":"type"}"#, #"{"action":"set_value","target":"e1"}"#,
                    #"{"action":"key","value":"cmd+nonsense"}"#, #"{"action":"scroll"}"#, #"{"action":"drag","target":"e1"}"#,
                    #"{"action":"drag","path":[{"x":1,"y":1}]}"#, #"{"action":"select","target":"e1"}"#, #"{"action":"click","to":{"x":1}}"#] {
            #expect(throws: ToolArgumentError.self, "\(bad)") { try parse(bad) }
        }
        #expect(try parse(#"{"action":"type","value":"hi"}"#).target == nil)
        #expect(try parse(#"{"action":"scroll","dy":-300}"#).dy == -300)
        #expect(try parse(#"{"action":"Double Click","target":"e1","observe":true}"#).kind == .doubleClick)
        let drag = try parse(#"{"action":"drag","path":[{"x":1,"y":1},{"x":5,"y":9},{"x":9,"y":9}]}"#)
        #expect(drag.path.count == 3 && drag.target == nil)
        #expect(try parse(#"{"action":"drag","target":"e1","to":{"x":50,"y":60}}"#).to == CGPoint(x: 50, y: 60))
    }

    @Test func selectsPopupOptionsOrMenuPaths() throws {
        let popup = try parse(#"{"action":"select","target":"Format","value":"PNG"}"#)
        #expect(popup.menuPath == nil)
        #expect(try parse(#"{"action":"select","value":"File > Export > PNG"}"#).menuPath == ["File", "Export", "PNG"])
        #expect(try parse(#"{"action":"select","target":"Edit>Undo"}"#).menuPath == ["Edit", "Undo"])
    }

    @Test func parsesKeyCombos() throws {
        let undo = try #require(ComputerAction.keyCombo("cmd+shift+z"))
        #expect(undo.modifiers == Hotkey.command | Hotkey.shift && undo.keyCode == KeyNames.code(for: "z"))
        #expect(ComputerAction.keyCombo("return")?.modifiers == 0)
        let zoomOut = try #require(ComputerAction.keyCombo("cmd+-"))
        #expect(zoomOut.modifiers == Hotkey.command && zoomOut.keyCode == KeyNames.code(for: "-"))
        #expect(ComputerAction.keyCombo("ctrl+nope") == nil)
        #expect(try parse(#"{"action":"key","value":"cmd+s"}"#).keys == Hotkey(keyCode: KeyNames.code(for: "s")!, modifiers: Hotkey.command))
    }
}

@Suite struct ComputerSceneTests {
    @Test func spaceConvertsBetweenGlobalAndImage() {
        let small = ComputerSpace(windowFrame: CGRect(x: 100, y: 50, width: 800, height: 600))
        #expect(small.scale == 1 && small.imageSize == CGSize(width: 800, height: 600))
        #expect(small.image(fromGlobal: CGPoint(x: 150, y: 80)) == CGPoint(x: 50, y: 30))
        #expect(small.global(fromImage: CGPoint(x: 50, y: 30)) == CGPoint(x: 150, y: 80))

        let big = ComputerSpace(windowFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        #expect(big.scale == 0.5 && big.imageSize == CGSize(width: 1280, height: 720))
        #expect(big.image(fromGlobal: CGPoint(x: -1280, y: 720)) == CGPoint(x: 640, y: 360))
        #expect(big.global(fromImage: CGPoint(x: 640, y: 360)) == CGPoint(x: -1280, y: 720))
        #expect(big.image(fromGlobal: CGRect(x: -2560, y: 0, width: 200, height: 100)) == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(big.containsImage(CGPoint(x: 1279, y: 719)) && !big.containsImage(CGPoint(x: 1280, y: 5)) && !big.containsImage(CGPoint(x: -1, y: 5)))
    }

    @Test func idsStayStable() {
        var ids = ComputerElementIDs()
        let a = ids.id(for: "window/button[Save]#0"), b = ids.id(for: "window/field#0")
        #expect(a == "e1" && b == "e2")
        #expect(ids.id(for: "window/button[Save]#0") == "e1" && ids.id(for: "x") == "e3")
    }

    private func element(_ id: String, _ role: String = "button", _ name: String = "", value: String = "", enabled: Bool = true, focused: Bool = false) -> ComputerElement {
        ComputerElement(id: id, role: role, name: name, value: value, enabled: enabled, focused: focused, frame: CGRect(x: 10, y: 20, width: 80, height: 24))
    }

    private func snapshot(_ elements: [ComputerElement], key: String = "A|w") -> ComputerSnapshot {
        ComputerSnapshot(app: "A", windowTitle: "w", windowKey: key, imageSize: CGSize(width: 800, height: 600), elements: elements)
    }

    @Test func diffsSnapshots() throws {
        let old = snapshot([element("e1", "button", "Open"), element("e2", "textfield", "Search", value: "a"), element("e3", "button", "Save")])
        let new = snapshot([element("e2", "textfield", "Search", value: "ab", focused: true), element("e3", "button", "Save", enabled: false),
                            element("e4", "dialog", "Export")])
        let diff = try #require(new.changes(since: old))
        #expect(diff.contains("+ e4 dialog “Export”"))
        #expect(diff.contains("- e1 button “Open”"))
        #expect(diff.contains("~ e2 textfield “Search”: value “a” → “ab”, now focused"))
        #expect(diff.contains("~ e3 button “Save”: now disabled"))
        #expect(new.changes(since: new) == "No change in the elements.")
        #expect(new.changes(since: snapshot([], key: "B|other")) == nil)
        let many = snapshot((0..<50).map { element("e\($0 + 10)", "button", "b\($0)") })
        let capped = try #require(many.changes(since: snapshot([]), limit: 5))
        #expect(capped.split(separator: "\n").count == 6 && capped.hasSuffix("…and 45 more changes"))
    }

    @Test func findsByNameBestMatchFirst() {
        let s = snapshot([element("e1", "button", "Save As…"), element("e2", "button", "Save"), element("e3", "textfield", "Name", value: "Saved")])
        #expect(s.find("save").map(\.id) == ["e2", "e1", "e3"])
        #expect(s.find("SAVED").map(\.id) == ["e3"])
        #expect(s.find("nothing").isEmpty && s.find("  ").isEmpty)
    }

    @Test func rendersAndWarnsWhenSparse() {
        var s = snapshot([element("e1", "button", "Save", value: "v", enabled: false, focused: true)])
        s.windows = [ComputerWindow(title: "w", isTarget: true), ComputerWindow(title: "other", isTarget: false)]
        s.menus = ["File", "Edit"]
        let text = s.render()
        #expect(text.contains(#"e1 button “Save” value=“v” disabled focused @10,20 80x24"#))
        #expect(text.contains("Windows: 1. “w” (this one), 2. “other”"))
        #expect(text.contains("Menu bar: File, Edit") && text.contains("exposes little") && text.contains("800x600"))
        let rich = snapshot((1...ComputerSnapshot.sparse).map { element("e\($0)") })
        #expect(!rich.render().contains("exposes little"))
    }
}

@Suite struct ComputerLabelTests {
    @Test func toolsReadNicelyInTheBubble() {
        let observe = ToolLabel(tool: ComputerTools.observe, arguments: #"{"app":"Safari"}"#)
        #expect(observe.title == "Looking at Safari" && observe.icon == "cursorarrow.click.2")
        #expect(ToolLabel(tool: ComputerTools.observe, arguments: "{}").title == "Looking at the screen")
        #expect(ToolLabel(tool: ComputerTools.act, arguments: #"{"action":"click","target":"Save"}"#).title == "Clicking “Save”")
        #expect(ToolLabel(tool: ComputerTools.act, arguments: #"{"action":"key","value":"cmd+s"}"#).title == "Pressing keys cmd+s")
        #expect(ToolLabel(tool: ComputerTools.act, arguments: #"{"action":"type","value":"hi"}"#).title == "Typing")
        #expect(ToolLabel(tool: ComputerTools.verify, arguments: #"{"condition":"dialog open"}"#).title == "Checking: dialog open")
    }
}
