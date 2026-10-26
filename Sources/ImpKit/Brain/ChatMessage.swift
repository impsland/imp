import Foundation

/// A model-requested function call. `arguments` is the raw JSON string from the model.
public struct ToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// A function the model may call (OpenAI `tools` entry).
public struct ToolSpec: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue = .object(["type": .string("object")])) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }

    var json: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": inputSchema.foundation]]
    }
}

/// The model's answer: text and/or tool calls.
public struct ChatReply: Hashable, Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public init(text: String, toolCalls: [ToolCall] = []) { self.text = text; self.toolCalls = toolCalls }
}

public struct ChatMessage: Codable, Hashable, Sendable {
    public var role: String
    /// Nil for assistant turns that only carry tool calls.
    public var content: String?
    public var toolCalls: [ToolCall]?
    /// For role "tool": the call this message answers.
    public var toolCallID: String?
    /// Pictures that go with a user turn (data URLs), for models that can see.
    public var images: [String]?

    public init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, images: [String]? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.images = images
    }

    public static func system(_ s: String) -> Self { .init(role: "system", content: s) }
    public static func user(_ s: String) -> Self { .init(role: "user", content: s) }
    /// A user turn with pictures attached.
    public static func user(_ s: String, images: [EncodedImage]) -> Self {
        .init(role: "user", content: s, images: images.isEmpty ? nil : images.map(\.dataURL))
    }
    public static func assistant(_ s: String) -> Self { .init(role: "assistant", content: s) }
    public static func assistant(_ s: String?, toolCalls: [ToolCall]) -> Self {
        .init(role: "assistant", content: s, toolCalls: toolCalls)
    }
    public static func tool(id: String, content: String) -> Self {
        .init(role: "tool", content: content, toolCallID: id)
    }

    /// Request-body form (OpenAI chat-completions).
    var json: [String: Any] {
        var d: [String: Any] = ["role": role]
        if let toolCalls, !toolCalls.isEmpty {
            d["content"] = content ?? NSNull()
            d["tool_calls"] = toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        } else if let images, !images.isEmpty {
            // Multimodal: the text, then each picture.
            d["content"] = [["type": "text", "text": content ?? ""]]
                + images.map { ["type": "image_url", "image_url": ["url": $0]] as [String: Any] }
        } else {
            d["content"] = content ?? ""
        }
        if let toolCallID { d["tool_call_id"] = toolCallID }
        return d
    }
}
