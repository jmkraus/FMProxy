import Foundation

struct ChatCompletionRequest: Decodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool?
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
