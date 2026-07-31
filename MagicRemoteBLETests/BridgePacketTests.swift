import XCTest
@testable import MagicRemoteBLE

final class BridgePacketTests: XCTestCase {
    func testParseMotion() {
        let data = Data([
            1, 7,
            0x0A, 0x00, // dx = 10
            0xF6, 0xFF, // dy = -10
            0x01, 0x00, // buttons
            0x02,       // wheel
        ])
        let pkt = BridgePacket.parse(data)
        XCTAssertEqual(pkt?.type, .motion)
        XCTAssertEqual(pkt?.seq, 7)
        XCTAssertEqual(pkt?.dx, 10)
        XCTAssertEqual(pkt?.dy, -10)
        XCTAssertEqual(pkt?.buttons, 1)
        XCTAssertEqual(pkt?.wheel, 2)
    }

    func testParseButton() {
        let data = Data([2, 3, 0x45, 0x01, 1])
        let pkt = BridgePacket.parse(data)
        XCTAssertEqual(pkt?.type, .button)
        XCTAssertEqual(pkt?.buttonCode, 0x0145)
        XCTAssertEqual(pkt?.buttonDown, true)
    }

    func testParseBatteryAndStatus() {
        XCTAssertEqual(BridgePacket.parse(Data([3, 1, 88]))?.battery, 88)
        XCTAssertEqual(BridgePacket.parse(Data([4, 1, 2]))?.status, 2)
    }

    func testRejectMalformed() {
        XCTAssertNil(BridgePacket.parse(Data([])))
        XCTAssertNil(BridgePacket.parse(Data([1, 0]))) // motion too short
        XCTAssertNil(BridgePacket.parse(Data([2, 0, 1]))) // button too short
        XCTAssertNil(BridgePacket.parse(Data([99, 0]))) // unknown type
    }

    func testInputPacketSinkDelivers() {
        let sink = InputPacketSink()
        let exp = expectation(description: "deliver")
        sink.setHandler { pkt in
            XCTAssertEqual(pkt.type, .button)
            XCTAssertEqual(pkt.buttonCode, 0x10)
            exp.fulfill()
        }
        sink.deliver(BridgePacket(type: .button, seq: 1, buttonCode: 0x10, buttonDown: true))
        wait(for: [exp], timeout: 1)
    }

    func testInputPacketSinkClears() {
        let sink = InputPacketSink()
        var hits = 0
        sink.setHandler { _ in hits += 1 }
        sink.setHandler(nil)
        sink.deliver(BridgePacket(type: .motion, seq: 0))
        XCTAssertEqual(hits, 0)
    }
}
