import Foundation

@available(macOS 26.0, *)
struct ChatCompletionsHandler: Sendable {
    private let modelClient = FoundationModelClient()
    private let encoder = JSONEncoder()
    private let modelName = "apple-foundation-model"

    func handle(body: Data) async -> HTTPResponse {
        do {
            let request = try validatedRequest(from: body)
            guard request.stream != true else {
                return .json(status: 500, body: error("internal streaming dispatch error"))
            }

            let content = try await modelClient.respond(to: request.messages, responseFormat: request.responseFormat)
            if let responseFormat = request.responseFormat {
                try validateStructuredOutput(content, responseFormat: responseFormat)
            }
            let response = ChatCompletionResponse(
                id: "chatcmpl-\(UUID().uuidString.lowercased())",
                created: Int(Date().timeIntervalSince1970),
                model: request.model ?? modelName,
                choices: [
                    .init(
                        index: 0,
                        message: .init(content: content),
                        finishReason: "stop"
                    )
                ],
                usage: .init()
            )
            return .json(status: 200, body: try encoder.encode(response))
        } catch let error as DecodingError {
            return .json(status: 400, body: self.error("invalid JSON request: \(error.localizedDescription)"))
        } catch let error as RequestValidationError {
            return .json(status: 400, body: self.error(error.localizedDescription))
        } catch {
            return .json(status: 503, body: self.error("Foundation Model request failed: \(error.localizedDescription)"))
        }
    }

    func streamingRequest(from body: Data) throws -> StreamingRequest? {
        let request = try validatedRequest(from: body)
        guard request.stream == true else { return nil }

        return StreamingRequest(
            id: "chatcmpl-\(UUID().uuidString.lowercased())",
            created: Int(Date().timeIntervalSince1970),
            model: request.model ?? modelName,
            messages: request.messages,
            responseFormat: request.responseFormat
        )
    }

    func stream(for request: StreamingRequest) -> AsyncThrowingStream<String, Error> {
        modelClient.stream(to: request.messages, responseFormat: request.responseFormat)
    }

    func encodeChunk(
        id: String,
        created: Int,
        model: String,
        content: String?,
        role: String? = nil,
        finishReason: String? = nil
    ) throws -> Data {
        let chunk = ChatCompletionChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                .init(
                    index: 0,
                    delta: .init(role: role, content: content),
                    finishReason: finishReason
                )
            ]
        )
        return try encoder.encode(chunk)
    }

    private func validatedRequest(from body: Data) throws -> ChatCompletionRequest {
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)

        guard !request.messages.isEmpty else {
            throw RequestValidationError.message("messages must not be empty")
        }

        let allowedRoles = Set(["system", "user", "assistant"])
        guard request.messages.allSatisfy({ allowedRoles.contains($0.role) }) else {
            throw RequestValidationError.message("unsupported message role")
        }

        if let responseFormat = request.responseFormat {
            switch responseFormat.type {
            case "text":
                break
            case "json_object":
                break
            case "json_schema":
                guard responseFormat.jsonSchema != nil else {
                    throw RequestValidationError.message("response_format.json_schema is required")
                }
            default:
                throw RequestValidationError.message("unsupported response_format type: \(responseFormat.type)")
            }
        }

        return request
    }

    private func validateStructuredOutput(_ content: String, responseFormat: ResponseFormat) throws {
        guard responseFormat.type == "json_object" || responseFormat.type == "json_schema" else { return }
        guard let data = content.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RequestValidationError.message("Foundation Model output was not valid JSON")
        }
        if responseFormat.type == "json_schema", let schema = responseFormat.jsonSchema?.schema {
            try JSONSchemaValidator.validate(value, against: schema)
        }
    }

    private func error(_ message: String) -> Data {
        (try? encoder.encode(OpenAIErrorResponse(error: .init(message: message, type: "invalid_request_error")))) ?? Data()
    }
}

struct StreamingRequest: Sendable {
    let id: String
    let created: Int
    let model: String
    let messages: [ChatMessage]
    let responseFormat: ResponseFormat?
}

enum JSONSchemaValidator {
    static func validate(_ value: JSONValue, against schema: JSONValue) throws {
        guard case .object(let definition) = schema else { return }

        if case .array(let values)? = definition["enum"], !values.contains(where: { equal($0, value) }) {
            throw RequestValidationError.message("output does not match schema enum")
        }

        if case .string(let type)? = definition["type"], !matches(value, type: type) {
            throw RequestValidationError.message("output does not match schema type \(type)")
        }

        switch value {
        case .object(let object):
            let properties: [String: JSONValue]
            if case .object(let declared)? = definition["properties"] { properties = declared } else { properties = [:] }
            if case .array(let required)? = definition["required"] {
                for item in required {
                    if case .string(let key) = item, object[key] == nil {
                        throw RequestValidationError.message("output is missing required property \(key)")
                    }
                }
            }
            if case .boolean(false)? = definition["additionalProperties"] {
                let unknown = object.keys.filter { properties[$0] == nil }
                if !unknown.isEmpty {
                    throw RequestValidationError.message("output contains unexpected property \(unknown[0])")
                }
            }
            for (key, propertySchema) in properties {
                if let property = object[key] { try validate(property, against: propertySchema) }
            }
        case .array(let values):
            if let itemSchema = definition["items"] {
                for value in values { try validate(value, against: itemSchema) }
            }
        default:
            break
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.boolean, "boolean"), (.null, "null"): return true
        case (.number, "number"), (.number, "integer"): return true
        default: return false
        }
    }

    private static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): return a.keys == b.keys && a.allSatisfy { equal($0.value, b[$0.key]!) }
        case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy(equal)
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

enum RequestValidationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
