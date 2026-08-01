import XCTest
@testable import MagicRemoteBLE

final class InputDeviceProfileTests: XCTestCase {
    func testDecodeMR25GAJSON() throws {
        let data = try loadMR25GAData()
        let profile = try JSONDecoder().decode(InputDeviceProfile.self, from: data)
        XCTAssertEqual(profile.id, "lg-mr25ga")
        XCTAssertFalse(profile.buttons.isEmpty)
        XCTAssertFalse(profile.defaultMaps.isEmpty)
        XCTAssertFalse(profile.pad.sections.isEmpty)

        let rows = profile.defaultKeyMapRows()
        XCTAssertEqual(rows.count, profile.defaultMaps.count)
        XCTAssertEqual(rows.first { $0.buttonCode == 0x808B }?.key, HIDKeyPresets.siriKey)

        let mouse = profile.resolvedMouseCodes
        XCTAssertEqual(mouse.left, 0x8044)
        XCTAssertEqual(mouse.right, 0x8043)
        XCTAssertEqual(mouse.back, 0x8028)
        XCTAssertTrue(profile.matches(bleName: "LGE MR25GA"))
    }

    func testHexParse() {
        XCTAssertEqual(HexCode.parseUInt16("0x8044"), 0x8044)
        XCTAssertEqual(HexCode.parseUInt8("0xFE"), 0xFE)
        XCTAssertEqual(HexCode.parseUInt8("0x00"), 0)
    }

    func testMouseBindingsFromProfile() throws {
        let profile = try JSONDecoder().decode(InputDeviceProfile.self, from: loadMR25GAData())
        let bindings = MouseButtonBindings(from: profile)
        XCTAssertEqual(bindings.left, 0x8044)
        XCTAssertEqual(bindings.right, 0x8043)
        XCTAssertEqual(bindings.back, 0x8028)
    }

    private func loadMR25GAData() throws -> Data {
        if let url = Bundle.main.url(forResource: "lg-mr25ga", withExtension: "json", subdirectory: "Profiles")
            ?? Bundle.main.url(forResource: "lg-mr25ga", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        /* Fallback: source tree next to this test file. */
        let this = URL(fileURLWithPath: #filePath)
        let json = this
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MagicRemoteBLE/Profiles/lg-mr25ga.json")
        return try Data(contentsOf: json)
    }
}
