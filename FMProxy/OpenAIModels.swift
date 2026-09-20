import Foundation

struct ChatCompletionRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case responseFormat = "response_format"
    }
}

struct ResponseFormat: Decodable, Sendable {
    let type: String
    let jsonSchema: JSONSchemaDefinition?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

struct JSONSchemaDefinition: Decodable, Sendable {
    let name: String?
    let strict: Bool?
    let schema: JSONValue
}

enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ChatMessage: Decodable, Sendable {
    let role: String
    let content: MessageContent?
}

enum MessageContent: Decodable, Sendable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([ContentPart].self))
        }
    }

    var textValue: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap(\.text).joined()
        }
    }
}

struct ContentPart: Decodable, Sendable {
    let type: String?
    let text: String?
}

struct ChatCompletionResponse: Encodable {
    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Encodable {
        let index: Int
        let message: AssistantMessage
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct AssistantMessage: Encodable {
        let role = "assistant"
        let content: String
    }

    struct Usage: Encodable {
        let promptTokens = 0
        let completionTokens = 0
        let totalTokens = 0

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct ChatCompletionChunk: Encodable {
    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index: Int
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Encodable {
        let role: String?
        let content: String?
    }
}

struct ModelsResponse: Encodable {
    let object = "list"
    let data: [Model]

    struct Model: Encodable {
        let id: String
        let object = "model"
        let created: Int
        let ownedBy = "apple"

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }
}

struct OpenAIErrorResponse: Encodable {
    let error: OpenAIError

    struct OpenAIError: Encodable {
        let message: String
        let type: String
        let param: String? = nil
        let code: String? = nil
    }
}
