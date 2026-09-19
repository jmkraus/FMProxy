import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct FoundationModelClient: Sendable {
    func respond(to messages: [ChatMessage]) async throws -> String {
        let prompt = makePrompt(from: messages)
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    func stream(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let prompt = makePrompt(from: messages)
        let session = LanguageModelSession()

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await response in session.streamResponse(to: prompt) {
                        continuation.yield(response.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makePrompt(from messages: [ChatMessage]) -> String {
        messages.map { message in
            let content = message.content?.textValue ?? ""
            return "\(message.role.uppercased()):\n\(content)"
        }.joined(separator: "\n\n") + "\n\nASSISTANT:"
    }
}
