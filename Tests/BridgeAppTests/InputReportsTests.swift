import XCTest
import NS2Transport

// report09 是独立输入格式；回归覆盖完整按钮表和真实日志中的原始摇杆值。
// Report09 is a distinct input format; regressions cover its full button table and raw stick values observed in real logs.
final class InputReportsTests: XCTestCase {
    private func decode(_ report: UInt32, _ packet: [UInt8]) -> (Int32, ns2_raw_input) {
        var result = ns2_raw_input()
        let valid = packet.withUnsafeBufferPointer {
            ns2_decode_input_report(report, $0.baseAddress, $0.count, &result)
        }
        return (valid, result)
    }

    func testReport09ButtonRowsMatchNintendoPositions() {
        // 独立列出协议的三个按钮字节；期望位保持 transport 的 Nintendo 顺序。
        // List the protocol's three button bytes independently; expected bits retain the transport's Nintendo order.
        let cases: [(Int, UInt8, Int, String)] = [
            (2, 0x01, 1, "B"), (2, 0x02, 0, "A"),
            (2, 0x04, 3, "Y"), (2, 0x08, 2, "X"),
            (2, 0x10, 7, "R"), (2, 0x20, 9, "ZR"),
            (2, 0x40, 10, "+"), (2, 0x80, 5, "RS"),
            (3, 0x01, 15, "Down"), (3, 0x02, 14, "Right"),
            (3, 0x04, 12, "Left"), (3, 0x08, 13, "Up"),
            (3, 0x10, 6, "L"), (3, 0x20, 8, "ZL"),
            (3, 0x40, 11, "-"), (3, 0x80, 4, "LS"),
            (4, 0x01, 16, "Home"), (4, 0x02, 17, "Capture"),
            (4, 0x04, 20, "GR"), (4, 0x08, 19, "GL"),
            (4, 0x10, 18, "C")
        ]
        for (byte, mask, bit, name) in cases {
            var packet = [UInt8](repeating: 0, count: 63)
            packet[byte] = mask
            let (valid, state) = decode(9, packet)
            XCTAssertEqual(valid, 1)
            XCTAssertEqual(state.buttons, UInt64(1) << bit, name)
        }
        var packet = [UInt8](repeating: 0, count: 63)
        packet[4] = 0xe0
        XCTAssertEqual(decode(9, packet).1.buttons, 0)
    }

    func testReport09UsesActualStickOffsetsAndPreservesUpwardRawY() {
        var packet = [UInt8](repeating: 0, count: 63)
        packet[0] = 0xfe
        packet[1] = 0x27
        packet.replaceSubrange(5...10, with: [0xe2, 0x07, 0x84, 0x8e, 0xbd, 0xbf])
        let (valid, state) = decode(9, packet)
        XCTAssertEqual(valid, 1)
        XCTAssertEqual(state.buttons, 0)
        XCTAssertEqual(state.lx, 2018)
        XCTAssertEqual(state.ly, 2112)
        XCTAssertEqual(state.rx, 3470)
        XCTAssertEqual(state.ry, 3067)
    }

    func testReports05And09YieldIdenticalCanonicalInput() {
        var report05 = [UInt8](repeating: 0, count: 63)
        report05[4] = 0x08
        report05[7] = 0x02
        report05.replaceSubrange(10...15, with: [0xe2, 0x07, 0x84, 0x8e, 0xbd, 0xbf])
        var report09 = [UInt8](repeating: 0, count: 63)
        report09[2] = 0x02
        report09[4] = 0x08
        report09.replaceSubrange(5...10, with: [0xe2, 0x07, 0x84, 0x8e, 0xbd, 0xbf])
        let (valid05, a) = decode(5, report05)
        let (valid09, b) = decode(9, report09)
        XCTAssertEqual(valid05, 1)
        XCTAssertEqual(valid09, 1)
        XCTAssertEqual(a.buttons, 1 | (1 << 19))
        XCTAssertEqual(a.buttons, b.buttons)
        XCTAssertEqual(a.lx, b.lx)
        XCTAssertEqual(a.ly, b.ly)
        XCTAssertEqual(a.rx, b.rx)
        XCTAssertEqual(a.ry, b.ry)
    }

    func testInputRejectsTruncatedUnknownAndMissingReports() {
        for report: UInt32 in [5, 9, 7] {
            for length in [0, 10, 62] {
                XCTAssertEqual(decode(report, [UInt8](repeating: 0, count: length)).0, 0)
            }
        }
        XCTAssertEqual(decode(7, [UInt8](repeating: 0, count: 63)).0, 0)
        var state = ns2_raw_input()
        state.buttons = .max
        state.lx = 4095
        XCTAssertEqual(ns2_decode_input_report(9, nil, 63, &state), 0)
        XCTAssertEqual(state.buttons, 0)
        XCTAssertEqual(state.lx, 0)
        XCTAssertEqual(ns2_decode_input_report(9, nil, 0, nil), 0)
    }
}
