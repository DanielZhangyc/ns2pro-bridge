import XCTest
import NS2Transport

// 只验证纯编码；使用已有实测频码和幅码，不启动蓝牙或发布虚拟设备。
// Verify only the pure codec with existing measured frequency/amplitude codes, without Bluetooth or a virtual device.
final class RumbleCodecTests: XCTestCase {
    private func encode(_ left: ns2_vibration, _ right: ns2_vibration = ns2_vibration(),
                        sequence: UInt8 = 0, gain: Float = 1) -> [UInt8] {
        let values = [left, right]
        var packet = [UInt8](repeating: 0, count: 42)
        values.withUnsafeBufferPointer { source in
            packet.withUnsafeMutableBufferPointer { destination in
                ns2_encode_rumble(source.baseAddress, sequence, gain, destination.baseAddress)
            }
        }
        return packet
    }

    func testMeasuredDualBandAndIndependentRightMotor() {
        let packet = encode(ns2_vibration(low_amp: 0.5, low_freq: 160, high_amp: 0.5, high_freq: 320),
                            ns2_vibration(low_amp: 0, low_freq: 0, high_amp: 0.5, high_freq: 640),
                            sequence: 31)
        // 160/320/640 Hz 对应频码 385/481/577；0.5 幅度在 gain 1 时对应幅码 96。
        // 160/320/640 Hz map to measured codes 385/481/577; amplitude 0.5 at gain 1 maps to code 96.
        XCTAssertEqual(packet[0], 0)
        XCTAssertEqual(packet[1], 0x5f)
        XCTAssertEqual(packet[17], 0x5f)
        XCTAssertEqual(Array(packet[2..<7]), [0x81, 0x81, 0x11, 0x1e, 0x18])
        XCTAssertEqual(Array(packet[18..<23]), [0, 0, 0x10, 0x24, 0x18])
        XCTAssertTrue(packet[7..<17].allSatisfy { $0 == 0 })
        XCTAssertTrue(packet[23..<42].allSatisfy { $0 == 0 })
    }

    func testStopPacketAndSequenceWrap() {
        let packet = encode(ns2_vibration(), sequence: 16, gain: 2)
        let expected = (0..<42).map { UInt8($0 == 1 || $0 == 17 ? 0x10 : 0) }
        XCTAssertEqual(packet, expected)
        let wrapped = encode(ns2_vibration(), sequence: 255)
        XCTAssertEqual(wrapped[1], 0x1f)
        XCTAssertEqual(wrapped[17], 0x1f)
    }

    func testDefaultGainUsesMeasuredAmplitudeCode192() {
        let value = ns2_vibration(low_amp: 0.5, low_freq: 160, high_amp: 0, high_freq: 0)
        let packet = encode(value, gain: 2)
        XCTAssertEqual(Array(packet[2..<7]), [0x81, 0x01, 0x03, 0, 0])
        XCTAssertEqual(packet[1], 0x50)
        XCTAssertEqual(encode(value, gain: 0), encode(ns2_vibration()))
    }

    func testNonfiniteAndNonpositiveCarriersCannotActivateBand() {
        let invalid = ns2_vibration(low_amp: .nan, low_freq: 160, high_amp: 1, high_freq: .nan)
        XCTAssertEqual(encode(invalid), encode(ns2_vibration()))
        let noCarrier = ns2_vibration(low_amp: 1, low_freq: 0, high_amp: 1, high_freq: -.infinity)
        XCTAssertEqual(encode(noCarrier), encode(ns2_vibration()))
        let highOnly = ns2_vibration(low_amp: 0, low_freq: 0, high_amp: 0.5, high_freq: 320)
        let invalidLow = ns2_vibration(low_amp: .infinity, low_freq: 160, high_amp: 0.5, high_freq: 320)
        XCTAssertEqual(encode(invalidLow), encode(highOnly))
    }

    func testClampsSupportedRangeAndRejectsInvalidGain() {
        let bounded = ns2_vibration(low_amp: 1, low_freq: 40, high_amp: 1, high_freq: 1252)
        let excessive = ns2_vibration(low_amp: 2, low_freq: 1, high_amp: 3, high_freq: 9000)
        XCTAssertEqual(encode(excessive, gain: 4), encode(bounded, gain: 4))
        for gain: Float in [-1, 4.01, .nan, .infinity] {
            XCTAssertEqual(encode(bounded, gain: gain), encode(ns2_vibration()))
        }
    }
}
