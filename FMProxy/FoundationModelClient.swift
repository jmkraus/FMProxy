import Foundation
import FoundationModels
import ImageIO

@available(macOS 27.0, *)
struct FoundationModelClient: Sendable {
    func respond(to messages: [ChatMessage], responseFormat: ResponseFormat? = nil) async throws -> String {
        let prompt = try makePrompt(from: messages, responseFormat: responseFormat)
        let session = LanguageModelSession()

        guard let schema = try generationSchema(for: responseFormat) else {
            let response = try await session.respond(to: prompt)
            return response.content
        }

        let response = try await session.respond(to: prompt, schema: schema)
        return response.content.jsonString
    }

    func stream(to messages: [ChatMessage], responseFormat: ResponseFormat? = nil) -> AsyncThrowingStream<String, Error> {
        do {
            let prompt = try makePrompt(from: messages, responseFormat: responseFormat)
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
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
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

    private func makePrompt(from messages: [ChatMessage], responseFormat: ResponseFormat?) throws -> Prompt {
        var components: [Prompt] = []

        for message in messages {
            components.append(Prompt("\(message.role.uppercased()):"))
            guard case .parts(let parts)? = message.content else {
                if case .text(let text)? = message.content {
                    components.append(Prompt(text))
                }
                continue
            }

            for part in parts {
                switch part.type {
                case "text":
                    components.append(Prompt(part.text ?? ""))
                case "image_url":
                    let data = try part.decodedImageData()
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw RequestValidationError.message("image data is not a supported image")
                    }
                    let attachment = Attachment<ImageAttachmentContent>(image)
                    components.append(Prompt(attachment))
                default:
                    throw RequestValidationError.message("unsupported content part type: \(part.type ?? "missing")")
                }
            }
        }

        components.append(Prompt("ASSISTANT:"))

        if let responseFormat {
            switch responseFormat.type {
            case "json_object":
                components.append(Prompt("Return only a valid JSON object. Do not use Markdown fences or add explanatory text."))
            case "json_schema" where responseFormat.jsonSchema != nil:
                let schemaData = try JSONEncoder().encode(responseFormat.jsonSchema!.schema)
                let schema = String(data: schemaData, encoding: .utf8) ?? "{}"
                components.append(Prompt("Return only valid JSON matching this JSON Schema. Do not use Markdown fences or add explanatory text. JSON Schema: \(schema)"))
            default:
                break
            }
        }

        return Prompt { components }
    }
}
