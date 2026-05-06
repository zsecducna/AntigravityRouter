import XCTest
@testable import AntigravityPorterCore

final class CONNECTParserTests: XCTestCase {

    // MARK: - Complete delivery

    func testParsesCompleteConnectRequest() throws {
        let raw = "CONNECT cloudcode-pa.googleapis.com:443 HTTP/1.1\r\nHost: cloudcode-pa.googleapis.com:443\r\n\r\n"
        let connect = try ConnectRequestParser.parse(Data(raw.utf8))

        XCTAssertEqual(connect.host, "cloudcode-pa.googleapis.com")
        XCTAssertEqual(connect.port, 443)
        XCTAssertEqual(connect.httpVersion, "HTTP/1.1")
    }

    func testParsesHeadersFromConnect() throws {
        let raw = "CONNECT example.com:8443 HTTP/1.1\r\nHost: example.com:8443\r\nProxy-Authorization: Basic abc\r\n\r\n"
        let connect = try ConnectRequestParser.parse(Data(raw.utf8))

        XCTAssertEqual(connect.host, "example.com")
        XCTAssertEqual(connect.port, 8443)
        XCTAssertEqual(connect.headers["proxy-authorization"], "Basic abc")
    }

    // MARK: - Split delivery (incomplete)

    func testThrowsIncompleteWhenNoLineTerminatorAtAll() {
        // No \n present — parser cannot find the end of the request line
        let raw = "CONNECT example.com:443 HTTP/1.1"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .incomplete)
        }
    }

    func testThrowsIncompleteWhenOnlyPartialRequestLine() {
        let raw = "CONNECT example"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .incomplete)
        }
    }

    // MARK: - Extra bytes after header delimiter

    func testIgnoresExtraBytesAfterHeaderDelimiter() throws {
        // Bytes after \r\n\r\n are post-CONNECT application data (e.g. start of TLS ClientHello)
        var raw = Data("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
        raw.append(contentsOf: [0x16, 0x03, 0x01, 0x00, 0x05]) // TLS record header
        let connect = try ConnectRequestParser.parse(raw)

        XCTAssertEqual(connect.host, "example.com")
        XCTAssertEqual(connect.port, 443)
    }

    // MARK: - Unsupported method → reject error

    func testThrowsUnsupportedMethodForGET() {
        let raw = "GET / HTTP/1.1\r\n\r\n"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .unsupportedMethod("GET"))
        }
    }

    func testThrowsUnsupportedMethodForPOST() {
        let raw = "POST /path HTTP/1.1\r\n\r\n"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .unsupportedMethod("POST"))
        }
    }

    // MARK: - Malformed authority

    func testThrowsInvalidAuthorityWhenPortMissing() {
        let raw = "CONNECT example.com HTTP/1.1\r\n\r\n"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .invalidAuthority("example.com"))
        }
    }

    func testThrowsInvalidPortWhenPortNotNumeric() {
        let raw = "CONNECT example.com:notaport HTTP/1.1\r\n\r\n"

        XCTAssertThrowsError(try ConnectRequestParser.parse(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? ConnectParseError, .invalidPort("notaport"))
        }
    }

    // MARK: - Edge cases

    func testAcceptsLFOnlyLineEndings() throws {
        let raw = "CONNECT example.com:443 HTTP/1.1\nHost: example.com\n\n"
        let connect = try ConnectRequestParser.parse(Data(raw.utf8))

        XCTAssertEqual(connect.host, "example.com")
        XCTAssertEqual(connect.port, 443)
    }
}
