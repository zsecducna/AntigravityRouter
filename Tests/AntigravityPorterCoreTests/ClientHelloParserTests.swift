import XCTest
@testable import AntigravityPorterCore

final class ClientHelloParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeClientHello(serverName: String, alpnProtocols: [String] = []) -> Data {
        let name = Array(serverName.utf8)
        let serverNameEntry = [UInt8(0), UInt8((name.count >> 8) & 0xff), UInt8(name.count & 0xff)] + name
        let sniBodyCount = serverNameEntry.count
        let sniBody = [UInt8((sniBodyCount >> 8) & 0xff), UInt8(sniBodyCount & 0xff)] + serverNameEntry
        let sniExt = [UInt8(0), UInt8(0), UInt8((sniBody.count >> 8) & 0xff), UInt8(sniBody.count & 0xff)] + sniBody

        var alpnExt: [UInt8] = []
        if !alpnProtocols.isEmpty {
            var protoList: [UInt8] = []
            for p in alpnProtocols {
                let pb = Array(p.utf8)
                protoList += [UInt8(pb.count)] + pb
            }
            let listLen = protoList.count
            let alpnData = [UInt8((listLen >> 8) & 0xff), UInt8(listLen & 0xff)] + protoList
            alpnExt = [UInt8(0), UInt8(0x10),
                       UInt8((alpnData.count >> 8) & 0xff), UInt8(alpnData.count & 0xff)] + alpnData
        }

        let extensions = sniExt + alpnExt
        let extLen = extensions.count

        let handshakeBody: [UInt8] =
            [0x03, 0x03] +
            Array(repeating: UInt8(0), count: 32) + // random
            [0] +                                    // session ID length
            [0, 2, 0x13, 0x01] +                    // cipher suites
            [1, 0] +                                 // compression methods
            [UInt8((extLen >> 8) & 0xff), UInt8(extLen & 0xff)] +
            extensions

        let hsLen = handshakeBody.count
        let handshake = [UInt8(0x01),
                         UInt8((hsLen >> 16) & 0xff), UInt8((hsLen >> 8) & 0xff), UInt8(hsLen & 0xff)] +
                        handshakeBody
        let recLen = handshake.count
        return Data([0x16, 0x03, 0x01,
                     UInt8((recLen >> 8) & 0xff), UInt8(recLen & 0xff)] + handshake)
    }

    private func makeClientHelloNoSNI() -> Data {
        // ClientHello with empty extensions block (length=0, no SNI or ALPN)
        let handshakeBody: [UInt8] =
            [0x03, 0x03] +
            Array(repeating: UInt8(0), count: 32) +
            [0] +
            [0, 2, 0x13, 0x01] +
            [1, 0] +
            [0, 0] // extensions length = 0
        let hsLen = handshakeBody.count
        let handshake = [UInt8(0x01),
                         UInt8((hsLen >> 16) & 0xff), UInt8((hsLen >> 8) & 0xff), UInt8(hsLen & 0xff)] +
                        handshakeBody
        let recLen = handshake.count
        return Data([0x16, 0x03, 0x01,
                     UInt8((recLen >> 8) & 0xff), UInt8(recLen & 0xff)] + handshake)
    }

    // MARK: - Complete delivery

    func testParsesCompleteSNI() throws {
        let data = makeClientHello(serverName: "cloudcode-pa.googleapis.com")

        let info = try ClientHelloParser.parse(data)

        XCTAssertEqual(info.sni, "cloudcode-pa.googleapis.com")
        XCTAssertTrue(info.alpn.isEmpty)
    }

    func testParsesALPNAlongWithSNI() throws {
        let data = makeClientHello(serverName: "example.com", alpnProtocols: ["http/1.1"])

        let info = try ClientHelloParser.parse(data)

        XCTAssertEqual(info.sni, "example.com")
        XCTAssertEqual(info.alpn, ["http/1.1"])
    }

    func testParsesMultipleALPNEntries() throws {
        let data = makeClientHello(serverName: "example.com", alpnProtocols: ["h2", "http/1.1"])

        let info = try ClientHelloParser.parse(data)

        XCTAssertEqual(info.alpn, ["h2", "http/1.1"])
    }

    // MARK: - Missing SNI

    func testMissingSNIReturnsNil() throws {
        let data = makeClientHelloNoSNI()

        let info = try ClientHelloParser.parse(data)

        XCTAssertNil(info.sni)
        XCTAssertTrue(info.alpn.isEmpty)
    }

    // MARK: - Split delivery (incomplete)

    func testThrowsIncompleteWhenFewerThanFiveBytes() {
        let data = Data([0x16, 0x03, 0x01])

        XCTAssertThrowsError(try ClientHelloParser.parse(data)) { error in
            XCTAssertEqual(error as? ClientHelloParseError, .incomplete)
        }
    }

    func testThrowsIncompleteWhenRecordTruncated() {
        let full = makeClientHello(serverName: "example.com")
        // Deliver only first half
        let partial = full.prefix(full.count / 2)

        XCTAssertThrowsError(try ClientHelloParser.parse(partial)) { error in
            XCTAssertEqual(error as? ClientHelloParseError, .incomplete)
        }
    }

    func testThrowsIncompleteWhenOnlyHeaderPresent() {
        // Valid 5-byte header, but no body
        let data = Data([0x16, 0x03, 0x01, 0x00, 0x40])

        XCTAssertThrowsError(try ClientHelloParser.parse(data)) { error in
            XCTAssertEqual(error as? ClientHelloParseError, .incomplete)
        }
    }

    // MARK: - Malformed

    func testThrowsMalformedWhenNotTLSContentType() {
        let data = Data([0x17, 0x03, 0x01, 0x00, 0x01, 0x00])

        XCTAssertThrowsError(try ClientHelloParser.parse(data)) { error in
            XCTAssertEqual(error as? ClientHelloParseError, .malformed)
        }
    }

    func testThrowsMalformedWhenHandshakeTypeNotClientHello() {
        // ContentType=0x16, Version=0x0301, Length=4, HandshakeType=0x02 (ServerHello)
        let data = Data([0x16, 0x03, 0x01, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00])

        XCTAssertThrowsError(try ClientHelloParser.parse(data)) { error in
            XCTAssertEqual(error as? ClientHelloParseError, .malformed)
        }
    }

    // MARK: - Extra application bytes after record (should not affect result)

    func testIgnoresTrailingBytesAfterCompleteRecord() throws {
        var data = makeClientHello(serverName: "example.com")
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF]) // early application data

        let info = try ClientHelloParser.parse(data)

        XCTAssertEqual(info.sni, "example.com")
    }
}
