import XCTest
import NS2Transport

final class MotionAccessoryTests: XCTestCase {
    // 公开的 Pro Controller 2 BLE 抓包，handle 0x000a 的 report05 通知，第 2147 帧。
    // Public Pro Controller 2 BLE capture, report05 notification on handle 0x000a, frame 2147.
    // https://github.com/ndeadly/switch2_controller_research/blob/master/captures/nrf52840/btle_procon2_motion_0x000A.pcapng
    private let report05 = "a30e0000000000000000af47842f38850000000000000000000000000000002f0d000000000000000001b7ab02000a00a7ff4d023510eeff03001400000000"

    // 同一研究仓库的 Pro Controller 2 配对抓包，handle 0x000e 的 report09 通知，第 514 帧。
    // Pro Controller 2 pairing capture from the same research repository, report09 notification on handle 0x000e, frame 514.
    // https://github.com/ndeadly/switch2_controller_research/blob/master/captures/nrf52840/btle_procon2_pairing_decrypted.pcapng
    private let report09 = "011c000000b3c784329883380000281780010f43fbff7dff3f1000e800e0f420d0f93ffbff064001e0f40ec8fc5ffd5f038001b8e93b200000000000000000"

    private func capturedBytes(_ hex: String) -> [UInt8] {
        precondition(hex.count.isMultiple(of: 2))
        let characters = Array(hex)
        return stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        }
    }

    func testCapturedReport05MotionValues() {
        let bytes = capturedBytes(report05)
        XCTAssertEqual(bytes.count, 63)
        var motion = ns2_motion()
        let result = bytes.withUnsafeBufferPointer {
            ns2_decode_report05_motion($0.baseAddress, $0.count, &motion)
        }
        XCTAssertEqual(result, 1)
        XCTAssertEqual(motion.known, 1)
        XCTAssertEqual(motion.report_counter, 3747)
        XCTAssertEqual(motion.device_timestamp_us, 175031)
        XCTAssertEqual(motion.host_timestamp_us, 0)
        XCTAssertEqual(motion.temperature_celsius, 25 + 10 / 126.9, accuracy: 0.001)
        XCTAssertEqual(motion.acceleration_x, -89 * 8 / 32767, accuracy: 0.00001)
        XCTAssertEqual(motion.acceleration_y, 589 * 8 / 32767, accuracy: 0.00001)
        XCTAssertEqual(motion.acceleration_z, 4149 * 8 / 32767, accuracy: 0.00001)
        XCTAssertEqual(motion.gyro_x, -18 * 2000 / 32767, accuracy: 0.0001)
        XCTAssertEqual(motion.gyro_y, 3 * 2000 / 32767, accuracy: 0.0001)
        XCTAssertEqual(motion.gyro_z, 20 * 2000 / 32767, accuracy: 0.0001)
    }

    func testCapturedReport05HasNoInsertedHeadsetBit() {
        let bytes = capturedBytes(report05)
        var info = ns2_info()
        let result = bytes.withUnsafeBufferPointer {
            ns2_decode_report05_accessories($0.baseAddress, $0.count, &info)
        }
        XCTAssertEqual(result, 1)
        XCTAssertEqual(info.headset_connected_known, 1)
        XCTAssertEqual(info.headset_connected, 0)
        XCTAssertEqual(info.headset_state_known, 0)
        XCTAssertEqual(info.nfc_state_known, 0)
    }

    func testCapturedReport09IdleAccessoryStates() {
        let bytes = capturedBytes(report09)
        XCTAssertEqual(bytes.count, 63)
        var info = ns2_info()
        let result = bytes.withUnsafeBufferPointer {
            ns2_decode_report09_accessories($0.baseAddress, $0.count, &info)
        }
        XCTAssertEqual(result, 1)
        XCTAssertEqual(info.nfc_state_known, 1)
        XCTAssertEqual(info.nfc_state, 0)
        XCTAssertEqual(info.headset_state_known, 1)
        XCTAssertEqual(info.headset_state, 0)
        XCTAssertEqual(info.headset_connected_known, 1)
        XCTAssertEqual(info.headset_connected, 0)
        XCTAssertEqual(info.headset_microphone_known, 1)
        XCTAssertEqual(info.headset_microphone, 0)
    }

    func testTruncatedCapturedReportsClearDecodedValues() {
        let report05Bytes = Array(capturedBytes(report05).dropLast())
        var motion = ns2_motion()
        motion.known = 1
        motion.report_counter = 3747
        XCTAssertEqual(report05Bytes.withUnsafeBufferPointer {
            ns2_decode_report05_motion($0.baseAddress, $0.count, &motion)
        }, 0)
        XCTAssertEqual(motion.known, 0)
        XCTAssertEqual(motion.report_counter, 0)
        XCTAssertEqual(motion.acceleration_z, 0)
        XCTAssertEqual(ns2_decode_report05_motion(nil, 63, &motion), 0)

        var info = ns2_info()
        info.headset_connected_known = 1
        info.headset_connected = 1
        XCTAssertEqual(report05Bytes.withUnsafeBufferPointer {
            ns2_decode_report05_accessories($0.baseAddress, $0.count, &info)
        }, 0)
        XCTAssertEqual(info.headset_connected_known, 0)
        XCTAssertEqual(info.headset_connected, 0)

        let report09Bytes = Array(capturedBytes(report09).dropLast())
        info.nfc_state_known = 1
        info.headset_state_known = 1
        XCTAssertEqual(report09Bytes.withUnsafeBufferPointer {
            ns2_decode_report09_accessories($0.baseAddress, $0.count, &info)
        }, 0)
        XCTAssertEqual(info.nfc_state_known, 0)
        XCTAssertEqual(info.headset_state_known, 0)
    }

    func testIdleMotionPollingReturnsUnknown() {
        var motion = ns2_motion()
        ns2_get_motion(&motion)
        XCTAssertEqual(motion.known, 0)
        XCTAssertEqual(motion.host_timestamp_us, 0)
        XCTAssertEqual(motion.device_timestamp_us, 0)
        XCTAssertEqual(motion.acceleration_x, 0)
        XCTAssertEqual(motion.gyro_x, 0)
        ns2_get_motion(nil)
    }
}
