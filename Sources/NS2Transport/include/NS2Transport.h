// 独立 Switch 2 Pro BLE 传输；只有显式 start 才会扫描或连接。
// Independent Switch 2 Pro BLE transport; only explicit start scans or connects.
#ifndef NS2_TRANSPORT_H
#define NS2_TRANSPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; } ns2_state;
typedef struct { float low_amp, low_freq, high_amp, high_freq; } ns2_vibration;
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
