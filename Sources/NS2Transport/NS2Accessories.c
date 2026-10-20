// 附件状态依据协议研究；保留未知耳机状态码，不从 NFC 状态推断卡片是否存在。
// Accessory states follow protocol research; preserve unknown headset codes and never infer tag presence from NFC state.
// https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md
#include "NS2Transport.h"

int ns2_decode_report05_accessories(const uint8_t *bytes, size_t length, ns2_info *out) {
    if (!out) return 0;
    out->headset_connected_known = out->headset_connected = 0;
    if (!bytes || length < 63) return 0;
    // report05 只有插入标志；不覆盖 report09 的原始音频状态与麦克风识别。
    // Report05 has insertion only; preserve report09 raw audio state and microphone classification.
    out->headset_connected_known = 1;
    out->headset_connected = (bytes[7] >> 4) & 1;
    if (!out->headset_connected) {
        out->headset_state_known = out->headset_state = 0;
        out->headset_microphone_known = out->headset_microphone = 0;
    }
    return 1;
}

int ns2_decode_report09_accessories(const uint8_t *bytes, size_t length, ns2_info *out) {
    if (!out) return 0;
    out->nfc_state_known = out->nfc_state = 0;
    out->headset_state_known = out->headset_state = 0;
    out->headset_connected_known = out->headset_connected = 0;
    out->headset_microphone_known = out->headset_microphone = 0;
    if (!bytes || length < 63) return 0;
    out->nfc_state = bytes[0x0c];
    out->nfc_state_known = out->nfc_state <= 7;
    out->headset_state_known = 1;
    out->headset_state = bytes[0x0d];
    switch (out->headset_state) {
        case 0: case 5: case 7: case 13: case 15:
            out->headset_connected_known = 1;
            out->headset_connected = out->headset_state != 0;
            out->headset_microphone_known = 1;
            out->headset_microphone = out->headset_state == 7 || out->headset_state == 15;
            break;
        default: break;
    }
    return 1;
}
