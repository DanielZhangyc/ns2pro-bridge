// 独立 Switch 2 Pro BLE 传输；只有显式 start 才会扫描或连接。
// Independent Switch 2 Pro BLE transport; only explicit start scans or connects.
#ifndef NS2_TRANSPORT_H
#define NS2_TRANSPORT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; } ns2_state;
typedef struct { uint64_t buttons; uint16_t lx, ly, rx, ry; } ns2_raw_input;
// 纯输入解码：report_id 为 5 或 9，四轴为未校准 12-bit 原始值；BLE 数据不含 report ID 前缀。
// Pure input decoding: report_id is 5 or 9, axes are uncalibrated 12-bit values; BLE data omits the report-ID prefix.
int ns2_decode_input_report(unsigned report_id, const uint8_t *bytes, size_t length, ns2_raw_input *out);
typedef struct { float low_amp, low_freq, high_amp, high_freq; } ns2_vibration;
typedef struct {
    uint8_t connected, ready;
    uint8_t battery_known;
    uint16_t battery_millivolts;
    uint8_t charging_raw_known, charging_raw;
    uint8_t charging_known, charging;
    uint8_t battery_level_known, battery_level;
    uint8_t external_power_known, external_power;
    uint8_t rssi_known;
    int32_t rssi_dbm;
    char name[128];
    char identifier[64];
    char telemetry_error[160];
} ns2_info;
// 轮询仅复制最后收到的数据，不触发扫描、连接或 RSSI 请求；RSSI 来自发现广播。
// Polling only copies the latest received data without scanning, connecting or requesting RSSI; RSSI comes from discovery advertisements.
void ns2_get_info(ns2_info *out);
// report05 为毫伏与原始充电字节；report09 为固件上报等级 0..9、充电及外接电源标志，均不是精确百分比。
// Report05 provides millivolts and a raw charge byte; report09 provides firmware levels 0..9, charging and external-power flags, never exact percentages.
// 纯解码只更新各自字段，保留另一种 report 的数据；无效输入返回 0 并清除本 report 的有效标志和值。
// Pure decoders update only their own fields and preserve the other report's data; invalid input returns 0 and clears this report's flags and values.
int ns2_decode_report05_telemetry(const uint8_t *bytes, size_t length, ns2_info *out);
int ns2_decode_report09_telemetry(const uint8_t *bytes, size_t length, ns2_info *out);
typedef enum {
    NS2_STATUS_IDLE, NS2_STATUS_SCANNING, NS2_STATUS_CONNECTING,
    NS2_STATUS_INITIALIZING, NS2_STATUS_READY, NS2_STATUS_DISCONNECTED,
    NS2_STATUS_UNAVAILABLE, NS2_STATUS_ERROR, NS2_STATUS_STOPPED
} ns2_status;
enum { NS2_CAP_LEFT = 1, NS2_CAP_RIGHT = 2, NS2_STICK_MAX = 32767 };
// Nintendo 位序：A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down；Y 向上为正。
// Nintendo bit order: A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down; positive Y is up.
// 扩展位16..20：Home Capture C GL GR；标准 Xbox 输出仅映射前两项。
// Extended bits16..20: Home Capture C GL GR; standard Xbox output maps only the first two.
// 回调在串行 BLE 队列调用；指针仅本次有效。context 必须存活到 shutdown 返回。
// Callbacks run on the serial BLE queue; pointers are valid only during the call. Keep context alive until shutdown returns.
typedef void (*ns2_state_callback)(const ns2_state *state, void *context);
typedef void (*ns2_status_callback)(ns2_status status, const char *message, void *context);

// 成功返回 1；重复启动或非法 NS2PRO_RUMBLE_GAIN 返回 0，尚未代表连接成功。
// Returns 1 on accepted start; duplicate start or invalid NS2PRO_RUMBLE_GAIN returns 0, without implying a connection.
int ns2_start(ns2_state_callback state, ns2_status_callback status, void *context);
void ns2_set_active(int active);
unsigned ns2_caps(void);
unsigned ns2_device_caps(void);
// side 为 0 左、1 右；幅度 0..1，频率 Hz，有限正载频限于 40..1252 Hz。
// side is 0 left or 1 right; amplitudes are 0..1, frequencies in Hz, with finite positive carriers clamped to 40..1252 Hz.
void ns2_send(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq);
// BLE 队列独立执行有效期；0停止，最大1000ms。普通 send 使用1000ms。
// The BLE queue independently enforces expiry; 0 stops, maximum1000ms. Plain send uses1000ms.
void ns2_send_lease(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq, unsigned duration_ms);
void ns2_actual(unsigned side, ns2_vibration *out);
// 立即清空两侧 mailbox，并安排零包；不撤销连接。
// Clear both mailboxes immediately and schedule a zero packet without disconnecting.
void ns2_stop_rumble(void);
// 返回 1 仅表示无连接或零包已交给 CoreBluetooth，不是电机确认。允许之后重新 start。
// Returns 1 only for no connection or a zero packet submitted to CoreBluetooth, never motor acknowledgement. A later start is allowed.
int ns2_shutdown(const char *reason, unsigned timeout_ms);
// 纯编码函数，不连接设备；完整 42-byte 双侧 report。
// Pure codec without device access; produces a complete 42-byte report for both sides.
void ns2_encode_rumble(const ns2_vibration values[2], uint8_t sequence, float gain, uint8_t out[42]);

#ifdef __cplusplus
}
#endif
#endif
