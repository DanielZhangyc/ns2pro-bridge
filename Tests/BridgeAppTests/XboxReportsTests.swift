import Foundation
import XCTest
@testable import BridgeApp

final class XboxReportsTests: XCTestCase {
    func testNeutralReportHasXboxBLELayout() {
        XCTAssertEqual(XboxReports.input(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0),
                       Data([1, 0,128, 0,128, 0,128, 0,128, 0,0, 0,0, 0,0,0,0]))
        XCTAssertEqual(XboxReports.descriptor.count, 283)
    }

    func testNintendoButtonsPreservePhysicalPositions() {
        for (source, expected): (Int, UInt8) in [(0,2),(1,1),(2,16),(3,8),(6,64),(7,128)] {
            let report = XboxReports.input(buttons: UInt64(1) << source, lx: 0, ly: 0, rx: 0, ry: 0)
            XCTAssertEqual(report[14], expected, "Nintendo bit \(source)")
            XCTAssertEqual(report[15], 0)
        }
        let report = XboxReports.input(buttons: (1 << 4) | (1 << 5) | (1 << 10) | (1 << 11),
                                       lx: 0, ly: 0, rx: 0, ry: 0)
        XCTAssertEqual(report[15], 0x6C)
    }

    func testDigitalTriggersAndHatAndAxisBounds() {
        let report = XboxReports.input(buttons: (1 << 8) | (1 << 9) | (1 << 13) | (1 << 14),
                                       lx: .min, ly: .max, rx: -32767, ry: 32767)
        XCTAssertEqual(Array(report[9...12]), [255, 3, 255, 3])
        XCTAssertEqual(report[13], 2)
        XCTAssertEqual(Array(report[1...8]), [1, 0, 255, 255, 1, 0, 255, 255])
        let opposed = XboxReports.input(buttons: (1 << 12) | (1 << 14), lx: 0, ly: 0, rx: 0, ry: 0)
        XCTAssertEqual(opposed[13], 0)
        let fragmentRisk = XboxReports.input(buttons: 0, lx: 255, ly: 0, rx: 0, ry: 0)
        XCTAssertEqual(fragmentRisk[1] & 0x80, 0)
    }

    func testPIDRumbleWithAndWithoutReportIDPrefix() throws {
        // SDL 的 BLE 输出格式：所有马达启用、主马达 60%/40%、2.55 秒持续。
        // SDL BLE output: all actuators enabled, 60%/40% main motors, 2.55 s sustain.
        let wire = Data([3, 15, 0, 0, 60, 40, 255, 0, 0])
        let decoded = try XboxReports.Rumble.decode(reportID: 3, data: wire)
        XCTAssertEqual(decoded.mask, 15)
        XCTAssertEqual(decoded.magnitudes, [0, 0, 0.6, 0.4])
        XCTAssertEqual(decoded.sustain, 2.55, accuracy: 1e-12)
        XCTAssertEqual(decoded.release, 0)
        XCTAssertEqual(decoded.repeats, 0)
        XCTAssertEqual(try XboxReports.Rumble.decode(reportID: 3, data: wire.dropFirst()), decoded)
        XCTAssertEqual(try XboxReports.Rumble.decode(reportID: nil, data: wire), decoded)
    }

    func testPIDMaskThreeIsNotMistakenForReportPrefix() throws {
        let payload = Data([3, 0, 0, 100, 50, 5, 2, 1])
        let decoded = try XboxReports.Rumble.decode(reportID: 3, data: payload)
        XCTAssertEqual(decoded.mask, 3)
        XCTAssertEqual(decoded.magnitudes, [0, 0, 1, 0.5])
        XCTAssertEqual(decoded.sustain, 0.05)
        XCTAssertEqual(decoded.release, 0.02)
        XCTAssertEqual(decoded.repeats, 1)
        let stop = try XboxReports.Rumble.decode(reportID: 3, data: Data([3, 15, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(stop.magnitudes, [0, 0, 0, 0])
    }

    func testMalformedAndUnsupportedReportsAreRejected() {
        for (id, data): (UInt8?, Data) in [
            (3, Data()), (3, Data([3,15,0,0,100,50])),
            (9, Data([3,15,0,0,100,50,5,0,0])),
            (3, Data([4,15,0,0,100,50,5,0,0])),
            (3, Data([15,0,0,101,50,5,0,0])),
            (3, Data([0xF0,0,0,100,50,5,0,0])),
            (nil, Data([15,0,0,100,50,5,0,0]))
        ] {
            XCTAssertThrowsError(try XboxReports.Rumble.decode(reportID: id, data: data))
        }
    }
}
