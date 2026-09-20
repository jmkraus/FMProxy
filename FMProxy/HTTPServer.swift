import Foundation
import Network

@available(macOS 26.0, *)
actor HTTPServer {
    private let configuration: ServerConfiguration
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FMProxy.HTTPServer")
    private let handler = ChatCompletionsHandler()
    private let logDateFormatter = ISO8601DateFormatter()
    private var isStopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationSlotAvailable = true
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: ServerConfiguration) throws {
        self.configuration = configuration

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ServerInitializationError.invalidPort(configuration.port)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )
        self.listener = try NWListener(using: parameters)
    }

    func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.accept(connection)
            }
        }
        listener.start(queue: queue)
    }

    func waitUntilStopped() async {
        if isStopped { return }

        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)

        listener.cancel()
        waiters.forEach { $0.resume() }
    }

    private func handleListenerState(_ state: NWListener.State) {
        if case .failed(let error) = state {
            fputs("Listener failed: \(error.localizedDescription)\n", stderr)
            stop()
        }
    }

    private func acquireGenerationSlot() async {
        if generationSlotAvailable {
            generationSlotAvailable = false
            return
        }

        await withCheckedContinuation { continuation in
            generationWaiters.append(continuation)
        }
    }

    private func releaseGenerationSlot() {
        if let waiter = generationWaiters.first {
            generationWaiters.removeFirst()
            waiter.resume()
        } else {
            generationSlotAvailable = true
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)

        let timeout = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(30))
                connection.cancel()
            } catch {
                // The timeout is cancelled when the request is received.
            }
        }
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(
        on connection: NWConnection,
        buffer: Data,
        timeout: Task<Void, Never>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = buffer
            received.append(contentsOf: data ?? Data())

            if received.count > HTTPRequest.maxRequestBytes {
                timeout.cancel()
                Task {
                    await self.reject(.payloadTooLarge, on: connection)
                }
                return
            }

            do {
                if let request = try HTTPRequest.parse(received) {
                    timeout.cancel()
                    Task {
                        await self.handle(request, on: connection)
                    }
                } else if isComplete || error != nil {
                    timeout.cancel()
                    connection.cancel()
                } else {
                    Task {
                        await self.receive(on: connection, buffer: received, timeout: timeout)
                    }
                }
            } catch let error as HTTPRequest.ParseError {
                timeout.cancel()
                Task {
                    await self.reject(error, on: connection)
                }
            } catch {
                timeout.cancel()
                Task {
                    await self.reject(.malformedRequest, on: connection)
                }
            }
        }
    }

    private func reject(_ error: HTTPRequest.ParseError, on connection: NWConnection) async {
        let response: HTTPResponse
        switch error {
        case .payloadTooLarge:
            response = .json(status: 413, body: errorResponse("Request body is too large"))
        case .malformedRequest, .unsupportedTransferEncoding:
            response = .json(status: 400, body: errorResponse(error.localizedDescription))
        }
        await send(response, on: connection)
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        let started = Date()
        var status = 200
        defer {
            log(request, status: status, duration: Date().timeIntervalSince(started))
        }

        if request.method == "POST", request.path == "/v1/chat/completions" {
            await acquireGenerationSlot()
            defer { releaseGenerationSlot() }

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
        var event = Data("data: ".utf8)
        event.append(json)
        event.append(contentsOf: Data("\n\n".utf8))
        return await sendData(event, on: connection)
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
        guard !configuration.noLogs else { return }
        let timestamp = logDateFormatter.string(from: Date())
        let milliseconds = Int(duration * 1_000)
        print("[\(timestamp)] \(request.method) \(request.path) -> \(status) (\(milliseconds) ms)")
    }
}

enum ServerInitializationError: LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid server port: \(port)"
        }
    }
}

struct HTTPRequest {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 10 * 1024 * 1024
    static let maxRequestBytes = maxHeaderBytes + maxBodyBytes

    let method: String
    let path: String
    let body: Data

    enum ParseError: LocalizedError, Sendable, Equatable {
        case malformedRequest
        case payloadTooLarge
        case unsupportedTransferEncoding

        var errorDescription: String? {
            switch self {
            case .malformedRequest:
                return "Malformed HTTP request"
            case .payloadTooLarge:
                return "Request body is too large"
            case .unsupportedTransferEncoding:
                return "Unsupported Transfer-Encoding"
            }
        }
    }

    private static let headerSeparator = Data([13, 10, 13, 10])

    static func parse(_ data: Data) throws -> HTTPRequest? {
        let separator = headerSeparator
        guard let headerEnd = data.range(of: separator) else {
            if data.count > maxHeaderBytes {
                throw ParseError.payloadTooLarge
            }
            return nil
        }

        guard headerEnd.upperBound <= maxHeaderBytes else {
            throw ParseError.payloadTooLarge
        }

        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformedRequest
        }

        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParseError.malformedRequest
        }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 3, components[2].hasPrefix("HTTP/") else {
            throw ParseError.malformedRequest
        }

        var contentLength: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ParseError.malformedRequest
            }

            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard let length = Int(value), length >= 0 else {
                    throw ParseError.malformedRequest
                }
                guard length <= maxBodyBytes else {
                    throw ParseError.payloadTooLarge
                }
                if let existingLength = contentLength, existingLength != length {
                    throw ParseError.malformedRequest
                }
                contentLength = length
            case "transfer-encoding":
                guard value.lowercased() == "identity" else {
                    throw ParseError.unsupportedTransferEncoding
                }
            default:
                break
            }
        }

        let bodyLength = contentLength ?? 0
        let bodyStart = headerEnd.upperBound
        guard bodyLength <= data.count - bodyStart else { return nil }

        return HTTPRequest(
            method: String(components[0]),
            path: String(components[1].split(separator: "?").first ?? ""),
            body: data.subdata(in: bodyStart..<(bodyStart + bodyLength))
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
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
