import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModelClient: Sendable {
    func respond(to messages: [ChatMessage], responseFormat: ResponseFormat? = nil) async throws -> String {
        let prompt = makePrompt(from: messages, responseFormat: responseFormat)
        let session = LanguageModelSession()

        guard let schema = try generationSchema(for: responseFormat) else {
            let response = try await session.respond(to: prompt)
            return response.content
        }

        let response = try await session.respond(to: prompt, schema: schema)
        return response.content.jsonString
    }

    func stream(to messages: [ChatMessage], responseFormat: ResponseFormat? = nil) -> AsyncThrowingStream<String, Error> {
        let prompt = makePrompt(from: messages, responseFormat: responseFormat)
        let session = LanguageModelSession()

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if let schema = try generationSchema(for: responseFormat) {
                        var finalContent = ""
                        for try await response in session.streamResponse(to: prompt, schema: schema) {
                            finalContent = response.content.jsonString
                        }
                        if !finalContent.isEmpty {
                            continuation.yield(finalContent)
                        }
                    } else {
                        for try await response in session.streamResponse(to: prompt) {
                            continuation.yield(response.content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generationSchema(for responseFormat: ResponseFormat?) throws -> GenerationSchema? {
        guard let responseFormat else { return nil }
        let schemaData: Data
        switch responseFormat.type {
        case "json_object":
            let schema: JSONValue = .object(["type": .string("object")])
            schemaData = try JSONEncoder().encode(normalize(schema, title: "response", isRoot: true))
        case "json_schema":
            guard let schema = responseFormat.jsonSchema?.schema else { return nil }
            schemaData = try JSONEncoder().encode(normalize(schema, title: responseFormat.jsonSchema?.name ?? "response", isRoot: true))
        default:
            return nil
        }
        return try JSONDecoder().decode(GenerationSchema.self, from: schemaData)
    }

    private func normalize(_ value: JSONValue, title: String, isRoot: Bool = false) -> JSONValue {
        guard case .object(var object) = value else { return value }
        if isRoot || (ifObjectType(object["type"])) {
            object["title"] = object["title"] ?? .string(title)
        }
        if case .string("string")? = object["type"], object["enum"] == nil {
            // Foundation Models currently requires an enum field for unconstrained
            // string properties. An empty enum is interpreted by GenerationSchema
            // as an unconstrained string; omitting it causes constrained generation
            // to reject otherwise valid string schemas. This normalization only
            // affects the generated Foundation Models schema, not the input schema.
            object["enum"] = .array([])
        }

        if case .object(let properties)? = object["properties"] {
            var normalizedProperties: [String: JSONValue] = [:]
            var order: [JSONValue] = []
            for (name, property) in properties {
                normalizedProperties[name] = normalize(property, title: name)
                order.append(.string(name))
            }
            object["properties"] = .object(normalizedProperties)
            object["x-order"] = object["x-order"] ?? .array(order)
        }

        if let items = object["items"] {
            object["items"] = normalize(items, title: "item")
        }
        return .object(object)
    }

    private func ifObjectType(_ value: JSONValue?) -> Bool {
        if case .string("object") = value { return true }
        return false
    }

    private func makePrompt(from messages: [ChatMessage], responseFormat: ResponseFormat?) -> String {
        let conversation = messages.map { message in
            let content = message.content?.textValue ?? ""
            return "\(message.role.uppercased()):\n\(content)"
        }.joined(separator: "\n\n")

        guard let responseFormat else {
            return conversation + "\n\nASSISTANT:"
        }

        let instruction: String
        switch responseFormat.type {
        case "json_object":
            instruction = "Return only a valid JSON object. Do not use Markdown fences or add explanatory text."
        case "json_schema" where responseFormat.jsonSchema != nil:
            let schemaData = try? JSONEncoder().encode(responseFormat.jsonSchema!.schema)
            let schema = schemaData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            instruction = "Return only valid JSON matching this JSON Schema. Do not use Markdown fences or add explanatory text. JSON Schema: \(schema)"
        default:
            instruction = ""
        }

        return conversation + "\n\nASSISTANT:\n" + instruction
    }
}
