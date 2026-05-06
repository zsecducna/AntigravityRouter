import XCTest
@testable import AntigravityPorterCore

final class ReplayBufferTests: XCTestCase {

    // MARK: - prepend(to:)

    func testPrependConcatenatesBufferedBytesBeforeNext() {
        let buffered = Data([0x01, 0x02, 0x03])
        let next     = Data([0x04, 0x05])
        var buf = InitialReplayBuffer(buffered: buffered)

        let result = buf.prepend(to: next)

        XCTAssertEqual(result, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testPrependSecondCallReturnsNextOnlyNoByteDuplication() {
        let buffered = Data([0xAA, 0xBB])
        var buf = InitialReplayBuffer(buffered: buffered)

        _ = buf.prepend(to: Data([0x01]))
        let second = buf.prepend(to: Data([0x02]))

        XCTAssertEqual(second, Data([0x02]))
    }

    func testPrependMarksBufferAsDrained() {
        var buf = InitialReplayBuffer(buffered: Data([0xFF]))

        XCTAssertFalse(buf.isDrained)
        _ = buf.prepend(to: Data())
        XCTAssertTrue(buf.isDrained)
    }

    // MARK: - drain()

    func testDrainReturnsBufferedBytes() {
        let buffered = Data([0x10, 0x20, 0x30])
        var buf = InitialReplayBuffer(buffered: buffered)

        let drained = buf.drain()

        XCTAssertEqual(drained, buffered)
    }

    func testDrainSecondCallReturnsEmpty() {
        var buf = InitialReplayBuffer(buffered: Data([0x01, 0x02]))

        _ = buf.drain()
        let second = buf.drain()

        XCTAssertEqual(second, Data())
    }

    func testDrainMarksBufferAsDrained() {
        var buf = InitialReplayBuffer(buffered: Data([0x01]))

        XCTAssertFalse(buf.isDrained)
        _ = buf.drain()
        XCTAssertTrue(buf.isDrained)
    }

    // MARK: - Byte order and no duplication invariants

    func testByteOrderPreservedInPrepend() {
        let buffered = Data("HELLO".utf8)
        let next     = Data(" WORLD".utf8)
        var buf = InitialReplayBuffer(buffered: buffered)

        let result = buf.prepend(to: next)

        XCTAssertEqual(String(decoding: result, as: UTF8.self), "HELLO WORLD")
    }

    func testEmptyBufferPrependReturnsNextUnchanged() {
        var buf = InitialReplayBuffer(buffered: Data())
        let next = Data([0x01, 0x02])

        let result = buf.prepend(to: next)

        XCTAssertEqual(result, next)
    }

    func testEmptyBufferDrainReturnsEmpty() {
        var buf = InitialReplayBuffer(buffered: Data())

        XCTAssertEqual(buf.drain(), Data())
    }

    func testDrainThenPrependReturnsNextOnly() {
        var buf = InitialReplayBuffer(buffered: Data([0xAA]))

        _ = buf.drain()
        let result = buf.prepend(to: Data([0xBB]))

        // Must not re-emit 0xAA
        XCTAssertEqual(result, Data([0xBB]))
    }

    func testPrependThenDrainReturnsEmpty() {
        var buf = InitialReplayBuffer(buffered: Data([0xAA]))

        _ = buf.prepend(to: Data([0xBB]))
        let result = buf.drain()

        // Must not re-emit 0xAA
        XCTAssertEqual(result, Data())
    }

    // MARK: - count

    func testCountReflectsBufferedSize() {
        let buf = InitialReplayBuffer(buffered: Data([1, 2, 3, 4, 5]))

        XCTAssertEqual(buf.count, 5)
    }
}
