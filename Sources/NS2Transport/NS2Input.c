// 按 report05 与 report09 各自布局解码，统一为 Nintendo 按钮位序和未校准摇杆值。
// Decode each report's distinct layout into common Nintendo button bits and uncalibrated stick values.
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md
#include "NS2Transport.h"
#include <string.h>

static void unpack_stick(const uint8_t *bytes, uint16_t *x, uint16_t *y) {
    *x = (uint16_t)(bytes[0] | (uint16_t)(bytes[1] & 15u) << 8);
    *y = (uint16_t)(bytes[1] >> 4 | (uint16_t)bytes[2] << 4);
}

int ns2_decode_input_report(unsigned report_id, const uint8_t *bytes, size_t length, ns2_raw_input *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!bytes || length < 63 || (report_id != 5 && report_id != 9)) return 0;
    static const uint8_t bits05[21] = {3, 2, 1, 0, 11, 10, 22, 6, 23, 7, 9, 8, 19, 17, 18, 16, 12, 13, 14, 25, 24};
    static const uint8_t bits09[21] = {1, 0, 3, 2, 15, 7, 12, 4, 13, 5, 6, 14, 10, 11, 9, 8, 16, 17, 20, 19, 18};
    const uint8_t *mapping = report_id == 5 ? bits05 : bits09;
    unsigned button_offset = report_id == 5 ? 4 : 2;
    uint32_t buttons = bytes[button_offset] | (uint32_t)bytes[button_offset + 1] << 8 |
        (uint32_t)bytes[button_offset + 2] << 16;
    if (report_id == 5) buttons |= (uint32_t)bytes[button_offset + 3] << 24;
    for (unsigned index = 0; index < 21; index++)
        if (buttons & (1u << mapping[index])) out->buttons |= 1ull << index;
    unsigned stick_offset = report_id == 5 ? 10 : 5;
    unpack_stick(bytes + stick_offset, &out->lx, &out->ly);
    unpack_stick(bytes + stick_offset + 3, &out->rx, &out->ry);
    return 1;
}
