import XCTest

final class FMProxyTests: XCTestCase {
    func testHTTPRequestParsesBodyAndQueryString() throws {
        let body = Data(#"{"messages":[]}"#.utf8)
        let requestData = Data(
            "POST /v1/chat/completions?stream=false HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + body

        let request = try XCTUnwrap(try HTTPRequest.parse(requestData))

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/chat/completions")
        XCTAssertEqual(request.body, body)
    }

    func testHTTPRequestWaitsForIncompleteBody() throws {
        let requestData = Data(
            "POST /health HTTP/1.1\r\nContent-Length: 4\r\n\r\nok".utf8
        )

        XCTAssertNil(try HTTPRequest.parse(requestData))
    }

    func testHTTPRequestRejectsMalformedContentLength() {
        let requestData = Data(
            "POST /health HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8
        )

        XCTAssertThrowsError(try HTTPRequest.parse(requestData)) { error in
            XCTAssertEqual(error as? HTTPRequest.ParseError, .malformedRequest)
        }
    }

    func testHTTPRequestRejectsUnsupportedTransferEncoding() {
        let requestData = Data(
            "POST /health HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        )

        XCTAssertThrowsError(try HTTPRequest.parse(requestData)) { error in
            XCTAssertEqual(error as? HTTPRequest.ParseError, .unsupportedTransferEncoding)
        }
    }

    func testJSONSchemaValidatesIntegerAndRequiredProperty() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("count")]),
            "properties": .object([
                "count": .object(["type": .string("integer")])
            ])
        ])

        try JSONSchemaValidator.validate(
            .object(["count": .number(3)]),
            against: schema
        )

        XCTAssertThrowsError(
            try JSONSchemaValidator.validate(
                .object(["count": .number(3.5)]),
                against: schema
            )
        )
    }

    func testJSONSchemaRejectsUnexpectedProperty() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
            "additionalProperties": .boolean(false)
        ])

        XCTAssertThrowsError(
            try JSONSchemaValidator.validate(
                .object(["name": .string("Ada"), "extra": .boolean(true)]),
                against: schema
            )
        )
    }

    func testServerConfigurationParsesOptions() {
        let configuration = ServerConfiguration(arguments: [
            "fmproxy-bin",
            "--host", "192.168.1.10",
            "--port", "9090",
            "--no-logs"
        ])

        XCTAssertEqual(configuration.host, "192.168.1.10")
        XCTAssertEqual(configuration.port, 9090)
        XCTAssertTrue(configuration.noLogs)
        XCTAssertFalse(configuration.showHelp)
    }

    func testHTTPResponseSerializesContentLength() {
        let response = HTTPResponse.text(status: 200, body: "ok")
        let serialized = String(decoding: response.serialized(), as: UTF8.self)

        XCTAssertTrue(serialized.contains("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(serialized.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(serialized.hasSuffix("\r\nok"))
    }
}
