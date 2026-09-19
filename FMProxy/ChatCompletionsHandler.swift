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

            let content = try await modelClient.respond(to: request.messages)
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
            messages: request.messages
        )
    }

    func stream(for request: StreamingRequest) -> AsyncThrowingStream<String, Error> {
        modelClient.stream(to: request.messages)
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

        return request
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
}

enum RequestValidationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
