import Foundation
import Network

@available(macOS 26.0, *)
final class HTTPServer: @unchecked Sendable {
    private let configuration: ServerConfiguration
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FMProxy.HTTPServer")
    private let handler = ChatCompletionsHandler()
    private let stopSemaphore = DispatchSemaphore(value: 0)

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        self.listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: configuration.port)!)
    }

    func start() throws {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("Listener failed: \(error.localizedDescription)\n", stderr)
                self.stop()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopSemaphore.wait()
                continuation.resume()
            }
        }
    }

    func stop() {
        listener.cancel()
        stopSemaphore.signal()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let received = buffer + (data ?? Data())

            if let request = HTTPRequest.parse(received) {
                Task {
                    await self.handle(request, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: received)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        let started = Date()
        var status = 200
        defer {
            log(request, status: status, duration: Date().timeIntervalSince(started))
        }

        if request.method == "POST", request.path == "/v1/chat/completions" {
            do {
                if let streamingRequest = try handler.streamingRequest(from: request.body) {
                    await sendStreaming(streamingRequest, on: connection)
                } else {
                    let response = await route(request)
                    status = response.status
                    await send(response, on: connection)
                }
            } catch let error as DecodingError {
                status = 400
                await send(.json(status: status, body: errorResponse("invalid JSON request: \(error.localizedDescription)")), on: connection)
            } catch let error as RequestValidationError {
                status = 400
                await send(.json(status: status, body: errorResponse(error.localizedDescription)), on: connection)
            } catch {
                status = 503
                await send(.json(status: status, body: errorResponse("Foundation Model request failed: \(error.localizedDescription)")), on: connection)
            }
        } else {
            let response = await route(request)
            status = response.status
            await send(response, on: connection)
        }
    }

    private func sendStreaming(_ request: StreamingRequest, on connection: NWConnection) async {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard await sendData(Data(headers.utf8), on: connection) else {
            connection.cancel()
            return
        }

        do {
            let roleChunk = try handler.encodeChunk(
                id: request.id,
                created: request.created,
                model: request.model,
                content: nil,
                role: "assistant"
            )
            guard await sendEvent(roleChunk, on: connection) else {
                connection.cancel()
                return
            }

            var previousContent = ""
            for try await content in handler.stream(for: request) {
                let delta: String
                if content.hasPrefix(previousContent) {
                    delta = String(content.dropFirst(previousContent.count))
                } else {
                    delta = content
                }
                previousContent = content

                if !delta.isEmpty {
                    let chunk = try handler.encodeChunk(
                        id: request.id,
                        created: request.created,
                        model: request.model,
                        content: delta
                    )
                    guard await sendEvent(chunk, on: connection) else {
                        connection.cancel()
                        return
                    }
                }
            }

            let finishChunk = try handler.encodeChunk(
                id: request.id,
                created: request.created,
                model: request.model,
                content: nil,
                finishReason: "stop"
            )
            guard await sendEvent(finishChunk, on: connection) else {
                connection.cancel()
                return
            }
            _ = await sendData(Data("data: [DONE]\n\n".utf8), on: connection)
        } catch {
            // The HTTP headers have already been sent, so only closing the
            // SSE connection is safe if generation fails.
            connection.cancel()
        }

        connection.cancel()
    }

    private func sendEvent(_ json: Data, on connection: NWConnection) async -> Bool {
        await sendData(Data("data: ".utf8) + json + Data("\n\n".utf8), on: connection)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) async {
        _ = await sendData(response.serialized(), on: connection)
        connection.cancel()
    }

    private func sendData(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .text(status: 200, body: "ok")
        case ("GET", "/v1/models"):
            let response = ModelsResponse(data: [.init(id: "apple-foundation-model", created: Int(Date().timeIntervalSince1970))])
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            return .json(status: 200, body: data)
        case ("POST", "/v1/chat/completions"):
            return await handler.handle(body: request.body)
        default:
            return .json(status: 404, body: errorResponse("Unknown endpoint"))
        }
    }

    private func errorResponse(_ message: String) -> Data {
        (try? JSONEncoder().encode(OpenAIErrorResponse(error: .init(message: message, type: "invalid_request_error")))) ?? Data()
    }

    private func log(_ request: HTTPRequest, status: Int, duration: TimeInterval) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let milliseconds = Int(duration * 1_000)
        print("[\(timestamp)] \(request.method) \(request.path) -> \(status) (\(milliseconds) ms)")
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let headerEnd = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let components = requestLine.split(separator: " ")
        guard components.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(components[0]),
            path: String(components[1].split(separator: "?").first ?? ""),
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static func json(status: Int, body: Data) -> HTTPResponse {
        HTTPResponse(status: status, reason: statusReason(status), contentType: "application/json", body: body)
    }

    static func text(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: statusReason(status), contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    func serialized() -> Data {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
