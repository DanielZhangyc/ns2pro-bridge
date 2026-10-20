// 使用公开的 report05 定长运动布局；不猜测 report09 的压缩数据。
// Use the published fixed report05 motion layout without guessing report09 packed data.
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md#motion-data
#include "NS2Transport.h"
#include <string.h>

static uint32_t read_u32(const uint8_t *p) {
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int read_i16(const uint8_t *p) {
    unsigned value = p[0] | (unsigned)p[1] << 8;
    return value < 0x8000 ? (int)value : (int)value - 0x10000;
}

int ns2_decode_report05_motion(const uint8_t *bytes, size_t length, ns2_motion *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!bytes || length < 63) return 0;
    out->known = 1;
    out->report_counter = read_u32(bytes);
    out->device_timestamp_us = read_u32(bytes + 0x2a);
    out->temperature_celsius = 25.0f + read_i16(bytes + 0x2e) / 126.9f;
    out->acceleration_x = read_i16(bytes + 0x30) * (8.0f / 32767.0f);
    out->acceleration_y = read_i16(bytes + 0x32) * (8.0f / 32767.0f);
    out->acceleration_z = read_i16(bytes + 0x34) * (8.0f / 32767.0f);
    out->gyro_x = read_i16(bytes + 0x36) * (2000.0f / 32767.0f);
    out->gyro_y = read_i16(bytes + 0x38) * (2000.0f / 32767.0f);
    out->gyro_z = read_i16(bytes + 0x3a) * (2000.0f / 32767.0f);
    return 1;
}
