import Foundation

// MARK: - ClientHelloInfo

/// Parsed information extracted from a TLS ClientHello handshake record.
public struct ClientHelloInfo: Equatable, Sendable {
    /// Server Name Indication, lowercased, or nil if absent.
    public var sni: String?
    /// ALPN protocol identifiers in preference order, e.g. ["http/1.1"].
    public var alpn: [String]

    public init(sni: String?, alpn: [String]) {
        self.sni = sni
        self.alpn = alpn
    }
}

// MARK: - ClientHelloParseError

public enum ClientHelloParseError: Error, Equatable, Sendable {
    /// Not enough bytes yet; caller should buffer and retry when more arrive.
    case incomplete
    /// Bytes present but structurally invalid (not a TLS ClientHello).
    case malformed
}

// MARK: - ClientHelloParser

/// Parses a TLS 1.x ClientHello record to extract SNI and ALPN.
///
/// Handles:
/// - Complete records delivered in one buffer.
/// - Split delivery: throws `.incomplete` so caller can accumulate.
/// - Malformed input: throws `.malformed`.
/// - Missing SNI: `info.sni == nil`.
/// - ALPN present: `info.alpn` is populated.
public enum ClientHelloParser {

    /// Parse raw bytes starting at the TLS record layer.
    /// - Throws: `ClientHelloParseError.incomplete` when more bytes are needed,
    ///           `ClientHelloParseError.malformed` on structural errors.
    public static func parse(_ data: Data) throws -> ClientHelloInfo {
        let bytes = [UInt8](data)

        // TLS record header: ContentType(1=0x16) + Version(2) + Length(2) = 5 bytes
        guard bytes.count >= 5 else { throw ClientHelloParseError.incomplete }
        guard bytes[0] == 0x16, bytes[1] == 0x03 else { throw ClientHelloParseError.malformed }

        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes.count >= recordLength + 5 else { throw ClientHelloParseError.incomplete }

        // Handshake header inside record: HandshakeType(1=0x01) + Length(3)
        guard bytes.count >= 9, bytes[5] == 0x01 else { throw ClientHelloParseError.malformed }

        // ClientHello body: ProtocolVersion(2) + Random(32)
        var index = 9
        guard bytes.count >= index + 2 + 32 else { throw ClientHelloParseError.incomplete }
        index += 2 + 32

        // SessionID: Length(1) + SessionID(n)
        guard bytes.count >= index + 1 else { throw ClientHelloParseError.incomplete }
        let sessionIDLength = Int(bytes[index])
        index += 1 + sessionIDLength

        // CipherSuites: Length(2) + Suites(n)
        guard bytes.count >= index + 2 else { throw ClientHelloParseError.incomplete }
        let cipherSuitesLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2 + cipherSuitesLength

        // CompressionMethods: Length(1) + Methods(n)
        guard bytes.count >= index + 1 else { throw ClientHelloParseError.incomplete }
        let compressionMethodsLength = Int(bytes[index])
        index += 1 + compressionMethodsLength

        // Extensions: Length(2) + Extensions(n)
        guard bytes.count >= index + 2 else { throw ClientHelloParseError.incomplete }
        let extensionsLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
        let extensionsEnd = index + extensionsLength
        guard bytes.count >= extensionsEnd else { throw ClientHelloParseError.incomplete }

        var sni: String? = nil
        var alpn: [String] = []

        while index + 4 <= extensionsEnd {
            let extType = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            let extLength = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 4
            guard index + extLength <= extensionsEnd else { throw ClientHelloParseError.malformed }
            let extSlice = Array(bytes[index ..< index + extLength])
            switch extType {
            case 0x0000: sni  = parseSNI(extSlice)
            case 0x0010: alpn = parseALPN(extSlice)
            default:     break
            }
            index += extLength
        }

        return ClientHelloInfo(sni: sni, alpn: alpn)
    }

    // MARK: - Private helpers

    private static func parseSNI(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 5 else { return nil }
        let listLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + listLength else { return nil }
        var index = 2
        let end = 2 + listLength
        while index + 3 <= end {
            let nameType   = bytes[index]
            let nameLength = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
            index += 3
            guard index + nameLength <= end else { return nil }
            if nameType == 0 {
                let name = String(decoding: bytes[index ..< index + nameLength], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return name.isEmpty ? nil : name
            }
            index += nameLength
        }
        return nil
    }

    private static func parseALPN(_ bytes: [UInt8]) -> [String] {
        guard bytes.count >= 2 else { return [] }
        let listLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + listLength else { return [] }
        var index = 2
        let end   = 2 + listLength
        var protocols: [String] = []
        while index + 1 <= end {
            let protoLength = Int(bytes[index])
            index += 1
            guard index + protoLength <= end, protoLength > 0 else { break }
            let proto = String(decoding: bytes[index ..< index + protoLength], as: UTF8.self)
            if !proto.isEmpty { protocols.append(proto) }
            index += protoLength
        }
        return protocols
    }
}
