// report05 字段依据公开协议研究；不对电压拟合百分比，不推断未知充电编码。
// Report05 fields follow the public protocol research; do not fit voltage to percentages or infer unknown charging codes.
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md#input-report-0x05
#include "NS2Transport.h"

int ns2_decode_report05_telemetry(const uint8_t *bytes, size_t length, ns2_info *out) {
    if (!out) return 0;
    out->battery_known = 0; out->battery_millivolts = 0;
    out->charging_raw_known = 0; out->charging_raw = 0;
    if (!bytes || length < 63) return 0;
    out->battery_known = 1;
    out->battery_millivolts = (uint16_t)(bytes[0x1f] | (uint16_t)bytes[0x20] << 8);
    out->charging_raw_known = 1;
    out->charging_raw = bytes[0x21];
    return 1;
}

// report09 总长 63 字节；电源字节 bit0 外接电源、bit1 充电、bit2..5 等级，bit6..7 保留。
// Report09 is 63 bytes; power byte bit0 is external power, bit1 charging, bits2..5 level, and bits6..7 reserved.
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md#input-report-0x09
int ns2_decode_report09_telemetry(const uint8_t *bytes, size_t length, ns2_info *out) {
    if (!out) return 0;
    out->battery_level_known = 0; out->battery_level = 0;
    out->charging_known = 0; out->charging = 0;
    out->external_power_known = 0; out->external_power = 0;
    if (!bytes || length < 63) return 0;
    uint8_t power = bytes[1], level = (power >> 2) & 0x0f;
    if (level > 9) return 0;
    out->battery_level_known = 1; out->battery_level = level;
    out->charging_known = 1; out->charging = (power >> 1) & 1;
    out->external_power_known = 1; out->external_power = power & 1;
    return 1;
}
