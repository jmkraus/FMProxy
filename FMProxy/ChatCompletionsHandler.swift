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
        if responseFormat.type == "json_object" {
            guard case .object = value else {
                throw RequestValidationError.message("Foundation Model output was not a JSON object")
            }
        } else if let schema = responseFormat.jsonSchema?.schema {
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

        if let schemas = definition["allOf"], case .array(let values) = schemas {
            for schema in values { try validate(value, against: schema) }
        }

        if let schemas = definition["anyOf"], case .array(let values) = schemas {
            guard values.contains(where: { (try? validate(value, against: $0)) != nil }) else {
                throw RequestValidationError.message("output does not match any schema alternative")
            }
        }

        if let schemas = definition["oneOf"], case .array(let values) = schemas {
            let matches = values.reduce(into: 0) { count, schema in
                if (try? validate(value, against: schema)) != nil { count += 1 }
            }
            guard matches == 1 else {
                throw RequestValidationError.message("output matches \(matches) schema alternatives; expected exactly one")
            }
        }

        if case .array(let values)? = definition["enum"], !values.contains(where: { equal($0, value) }) {
            throw RequestValidationError.message("output does not match schema enum")
        }

        if let constant = definition["const"], !equal(constant, value) {
            throw RequestValidationError.message("output does not match schema const")
        }

        if let type = definition["type"], !matches(value, typeDefinition: type) {
            throw RequestValidationError.message("output does not match schema type")
        }

        switch value {
        case .object(let object):
            try validateObject(object, definition: definition)
        case .array(let values):
            try validateArray(values, definition: definition)
        case .string(let string):
            try validateString(string, definition: definition)
        case .number(let number):
            try validateNumber(number, definition: definition)
        default:
            break
        }
    }

    private static func validateObject(
        _ object: [String: JSONValue],
        definition: [String: JSONValue]
    ) throws {
        if case .number(let minimum)? = definition["minProperties"], Double(object.count) < minimum {
            throw RequestValidationError.message("output has fewer properties than allowed")
        }
        if case .number(let maximum)? = definition["maxProperties"], Double(object.count) > maximum {
            throw RequestValidationError.message("output has more properties than allowed")
        }

        let properties: [String: JSONValue]
        if case .object(let declared)? = definition["properties"] {
            properties = declared
        } else {
            properties = [:]
        }

        if case .array(let required)? = definition["required"] {
            for item in required {
                if case .string(let key) = item, object[key] == nil {
                    throw RequestValidationError.message("output is missing required property \(key)")
                }
            }
        }

        let unknown = object.keys.filter { properties[$0] == nil }
        if case .boolean(false)? = definition["additionalProperties"], !unknown.isEmpty {
            throw RequestValidationError.message("output contains unexpected property \(unknown[0])")
        }
        if case .object(let additionalSchema)? = definition["additionalProperties"] {
            for key in unknown {
                try validate(object[key]!, against: .object(additionalSchema))
            }
        }

        for (key, propertySchema) in properties {
            if let property = object[key] {
                try validate(property, against: propertySchema)
            }
        }
    }

    private static func validateArray(
        _ values: [JSONValue],
        definition: [String: JSONValue]
    ) throws {
        if case .number(let minimum)? = definition["minItems"], Double(values.count) < minimum {
            throw RequestValidationError.message("output has fewer items than allowed")
        }
        if case .number(let maximum)? = definition["maxItems"], Double(values.count) > maximum {
            throw RequestValidationError.message("output has more items than allowed")
        }
        if case .boolean(true)? = definition["uniqueItems"] {
            for index in values.indices {
                if values[(index + 1)..<values.endIndex].contains(where: { equal(values[index], $0) }) {
                    throw RequestValidationError.message("output contains duplicate array items")
                }
            }
        }
        if let itemSchema = definition["items"] {
            for value in values { try validate(value, against: itemSchema) }
        }
    }

    private static func validateString(
        _ string: String,
        definition: [String: JSONValue]
    ) throws {
        if case .number(let minimum)? = definition["minLength"], Double(string.count) < minimum {
            throw RequestValidationError.message("output string is shorter than allowed")
        }
        if case .number(let maximum)? = definition["maxLength"], Double(string.count) > maximum {
            throw RequestValidationError.message("output string is longer than allowed")
        }
        if case .string(let pattern)? = definition["pattern"] {
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            guard (try? NSRegularExpression(pattern: pattern)).flatMap({ $0.firstMatch(in: string, range: range) }) != nil else {
                throw RequestValidationError.message("output string does not match schema pattern")
            }
        }
    }

    private static func validateNumber(
        _ number: Double,
        definition: [String: JSONValue]
    ) throws {
        guard number.isFinite else {
            throw RequestValidationError.message("output number is not finite")
        }
        if case .string("integer")? = definition["type"], number.rounded() != number {
            throw RequestValidationError.message("output number is not an integer")
        }
        if case .number(let minimum)? = definition["minimum"], number < minimum {
            throw RequestValidationError.message("output number is below the minimum")
        }
        if case .number(let maximum)? = definition["maximum"], number > maximum {
            throw RequestValidationError.message("output number is above the maximum")
        }
        if case .number(let exclusiveMinimum)? = definition["exclusiveMinimum"], number <= exclusiveMinimum {
            throw RequestValidationError.message("output number is not above the exclusive minimum")
        }
        if case .number(let exclusiveMaximum)? = definition["exclusiveMaximum"], number >= exclusiveMaximum {
            throw RequestValidationError.message("output number is not below the exclusive maximum")
        }
    }

    private static func matches(_ value: JSONValue, typeDefinition: JSONValue) -> Bool {
        let types: [String]
        switch typeDefinition {
        case .string(let type): types = [type]
        case .array(let values): types = values.compactMap {
            if case .string(let type) = $0 { return type }
            return nil
        }
        default: return false
        }
        return types.contains(where: { matches(value, type: $0) })
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.boolean, "boolean"), (.null, "null"):
            return true
        case (.number, "number"):
            return true
        case (.number(let number), "integer"):
            return number.isFinite && number.rounded() == number
        default:
            return false
        }
    }

    private static func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            return a.keys == b.keys && a.allSatisfy { key, value in
                guard let other = b[key] else { return false }
                return equal(value, other)
            }
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy(equal)
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
