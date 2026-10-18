import XCTest
import NS2Transport

// 纯协议解码测试；字段向量来自公开布局，不启动 BLE 或虚拟手柄。
// Pure protocol decoding tests using vectors from the published layout, without BLE or virtual devices.
final class TelemetryTests: XCTestCase {
    private func decode(_ packet: [UInt8]) -> (Int32, ns2_info) {
        var info = ns2_info()
        let result = packet.withUnsafeBufferPointer {
            ns2_decode_report05_telemetry($0.baseAddress, $0.count, &info)
        }
        return (result, info)
    }

    func testReport05ReadsBatteryMillivoltsLittleEndian() {
        var packet = [UInt8](repeating: 0, count: 63)
        // 0x0EA5 = 3749 mV；协议研究的电压命令响应也使用该原始值。
        // 0x0EA5 = 3749 mV; the protocol research's battery command response uses the same raw value.
        packet[0x1f] = 0xa5
        packet[0x20] = 0x0e
        packet[0x21] = 0x34
        let (result, info) = decode(packet)
        XCTAssertEqual(result, 1)
        XCTAssertEqual(info.battery_known, 1)
        XCTAssertEqual(info.battery_millivolts, 3749)
        XCTAssertEqual(info.charging_raw_known, 1)
        XCTAssertEqual(info.charging_raw, 0x34)
        XCTAssertEqual(info.charging_known, 0)
        XCTAssertEqual(info.connected, 0)
        XCTAssertEqual(info.ready, 0)
        XCTAssertEqual(info.rssi_known, 0)
    }

    func testRawChargingValuesArePreservedWithoutGuessingFlags() {
        for raw: UInt8 in [0, 0x20, 0x34, 0xff] {
            var packet = [UInt8](repeating: 0, count: 63)
            packet[0x1f] = 0x68
            packet[0x20] = 0x10
            packet[0x21] = raw
            let (result, info) = decode(packet)
            XCTAssertEqual(result, 1)
            XCTAssertEqual(info.battery_millivolts, 4200)
            XCTAssertEqual(info.charging_raw, raw)
            XCTAssertEqual(info.charging_known, 0)
            XCTAssertEqual(info.charging, 0)
        }
    }

    func testTruncatedAndMissingReportsClearOutput() {
        for length in [0, 1, 31, 33, 62] {
            var info = ns2_info()
            info.battery_known = 1
            info.battery_millivolts = 4200
            info.charging_raw_known = 1
            info.charging_raw = 0x34
            let packet = [UInt8](repeating: 0xff, count: length)
            let result = packet.withUnsafeBufferPointer {
                ns2_decode_report05_telemetry($0.baseAddress, $0.count, &info)
            }
            XCTAssertEqual(result, 0)
            XCTAssertEqual(info.battery_known, 0)
            XCTAssertEqual(info.battery_millivolts, 0)
            XCTAssertEqual(info.charging_raw_known, 0)
            XCTAssertEqual(info.charging_raw, 0)
        }
        var info = ns2_info()
        XCTAssertEqual(ns2_decode_report05_telemetry(nil, 63, &info), 0)
        XCTAssertEqual(ns2_decode_report05_telemetry(nil, 0, nil), 0)
    }

    func testIdlePollingDoesNotInventConnectionOrBattery() {
        var info = ns2_info()
        ns2_get_info(&info)
        XCTAssertEqual(info.connected, 0)
        XCTAssertEqual(info.ready, 0)
        XCTAssertEqual(info.battery_known, 0)
        XCTAssertEqual(info.charging_known, 0)
        XCTAssertEqual(info.charging_raw_known, 0)
        XCTAssertEqual(info.rssi_known, 0)
        XCTAssertEqual(info.battery_level_known, 0)
        XCTAssertEqual(info.external_power_known, 0)
        ns2_get_info(nil)
    }

    func testReport09PowerBitsAndFirmwareLevels() {
        for level: UInt8 in [0, 1, 5, 9] {
            for flags: UInt8 in [0, 1, 2, 3] {
                var packet = [UInt8](repeating: 0, count: 63)
                packet[1] = (level << 2) | flags
                var info = ns2_info()
                let result = packet.withUnsafeBufferPointer {
                    ns2_decode_report09_telemetry($0.baseAddress, $0.count, &info)
                }
                XCTAssertEqual(result, 1)
                XCTAssertEqual(info.battery_level_known, 1)
                XCTAssertEqual(info.battery_level, level)
                XCTAssertEqual(info.external_power_known, 1)
                XCTAssertEqual(info.external_power, flags & 1)
                XCTAssertEqual(info.charging_known, 1)
                XCTAssertEqual(info.charging, (flags >> 1) & 1)
                XCTAssertEqual(info.battery_known, 0)
            }
        }
    }

    func testInterleavedReportsPreserveEachOthersPowerFields() {
        var report09 = [UInt8](repeating: 0, count: 63)
        report09[1] = 0x27
        var info = ns2_info()
        XCTAssertEqual(report09.withUnsafeBufferPointer {
            ns2_decode_report09_telemetry($0.baseAddress, $0.count, &info)
        }, 1)
        var report05 = [UInt8](repeating: 0, count: 63)
        report05[0x1f] = 0xa5
        report05[0x20] = 0x0e
        report05[0x21] = 0x34
        XCTAssertEqual(report05.withUnsafeBufferPointer {
            ns2_decode_report05_telemetry($0.baseAddress, $0.count, &info)
        }, 1)
        XCTAssertEqual(info.battery_millivolts, 3749)
        XCTAssertEqual(info.charging_raw, 0x34)
        XCTAssertEqual(info.battery_level_known, 1)
        XCTAssertEqual(info.battery_level, 9)
        XCTAssertEqual(info.charging_known, 1)
        XCTAssertEqual(info.charging, 1)
        XCTAssertEqual(info.external_power, 1)
        report09[1] = 0x14
        XCTAssertEqual(report09.withUnsafeBufferPointer {
            ns2_decode_report09_telemetry($0.baseAddress, $0.count, &info)
        }, 1)
        XCTAssertEqual(info.battery_millivolts, 3749)
        XCTAssertEqual(info.battery_known, 1)
        XCTAssertEqual(info.battery_level, 5)
        XCTAssertEqual(info.charging, 0)
        XCTAssertEqual(info.external_power, 0)
    }

    func testInvalidReport09ClearsOnlySecondaryPowerFields() {
        for (length, power): (Int, UInt8) in [(0, 0), (2, 0x27), (62, 0x27), (63, 0x28), (63, 0x3f)] {
            var info = ns2_info()
            info.battery_known = 1
            info.battery_millivolts = 3749
            info.battery_level_known = 1
            info.battery_level = 9
            info.charging_known = 1
            info.charging = 1
            info.external_power_known = 1
            info.external_power = 1
            var packet = [UInt8](repeating: 0, count: length)
            if length > 1 { packet[1] = power }
            XCTAssertEqual(packet.withUnsafeBufferPointer {
                ns2_decode_report09_telemetry($0.baseAddress, $0.count, &info)
            }, 0)
            XCTAssertEqual(info.battery_level_known, 0)
            XCTAssertEqual(info.charging_known, 0)
            XCTAssertEqual(info.external_power_known, 0)
            XCTAssertEqual(info.battery_millivolts, 3749)
            XCTAssertEqual(info.battery_known, 1)
        }
        var info = ns2_info()
        XCTAssertEqual(ns2_decode_report09_telemetry(nil, 63, &info), 0)
        XCTAssertEqual(ns2_decode_report09_telemetry(nil, 0, nil), 0)
    }
}
