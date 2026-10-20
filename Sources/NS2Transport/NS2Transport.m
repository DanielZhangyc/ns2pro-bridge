// 原生 Switch 2 Pro BLE：工厂校准输入、顺序命令握手、双侧有界震动 mailbox。
// Native Switch 2 Pro BLE: factory-calibrated input, ordered handshake and a bounded two-side rumble mailbox.
// 协议依据 / Protocol references:
// https://github.com/ndeadly/switch2_controller_research (bluetooth_interface.md, commands.md, hid_reports.md)
// https://github.com/murphyjt/wavebird (BLE / NS2Commands, MIT)
// https://github.com/caqlayan/procon2-mac (BLEController, MIT)
// 仅采用协议布局与校准关系，生命周期和线程模型为本桥独立实现。
// Protocol layouts and calibration relations inform this independently implemented lifecycle and threading model.
/*
MIT License
Copyright (c) 2026 jhaizhou
Copyright (c) 2026 Joshua Murphy
Copyright (c) 2026 Arda Caglayan Ercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
#import <CoreBluetooth/CoreBluetooth.h>
#include "NS2Transport.h"
#include <math.h>
#include <pthread.h>
#include <errno.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define LOG(...) do { fprintf(stderr, "[NS2Transport] "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define NS2Localized(key) NSLocalizedStringFromTable((key), @"Transport", nil)
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static NSString *const serviceUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0";
static NSString *const inputUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2";
static NSString *const powerUUID = @"7492866C-EC3E-4619-8258-32755FFCC0F8";
static NSString *const vibrationUUID = @"CC483F51-9258-427D-A939-630C31F72B05";
static NSString *const commandUUID = @"649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005";
static NSString *const responseUUID = @"C765A961-D9D8-4D36-A20A-5315B111836A";

// 调用线程只更新固定 mailbox；CB 对象始终局限于串行队列，不逐请求创建 block。
// Caller threads only update the fixed mailbox; CB objects stay on one serial queue, without a block per request.
static pthread_mutex_t stateMu = PTHREAD_MUTEX_INITIALIZER;
static ns2_vibration wanted[2], actual[2];
static uint64_t wantedDeadline[2];
static BOOL active, ready, terminal = YES, dirty, shutdownSent;
static unsigned stopMask;
static dispatch_queue_t bleQueue;
static dispatch_group_t shutdownGroup;
static char queueKey;
static float rumbleGain = 2;
static ns2_info deviceInfo;
static ns2_motion latestMotion;
static ns2_state_callback stateCallback;
static ns2_status_callback statusCallback;
static ns2_motion_callback motionCallback;
static void *callbackContext;
static BOOL disposing;
static void emit_state(ns2_state value) { if (stateCallback) stateCallback(&value, callbackContext); }
static void emit_status(ns2_status value, NSString *message) { if (statusCallback) statusCallback(value, message.UTF8String, callbackContext); }
static void on_queue(dispatch_block_t block) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bleQueue = dispatch_queue_create("ns2pro.transport.ble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(bleQueue, &queueKey, &queueKey, NULL);
    });
    if (dispatch_get_specific(&queueKey)) block(); else dispatch_sync(bleQueue, block);
}

typedef struct { unsigned center[2], above[2], below[2]; } ns2_calibration;
static void unpack12(const uint8_t *p, unsigned out[2]) {
    out[0] = p[0] | (p[1] & 15u) << 8; out[1] = p[1] >> 4 | (unsigned)p[2] << 4;
}
static uint32_t le32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static BOOL uuid_is(CBUUID *uuid, NSString *text) { return [uuid isEqual:[CBUUID UUIDWithString:text]]; }
static BOOL value_nonzero(ns2_vibration value) { return value.low_amp > 0 || value.high_amp > 0; }
static void reset_state(void) {
    pthread_mutex_lock(&stateMu);
    // 断线后立即丢弃旧物理连接的输入和震动数值。
    // Immediately discard old physical input and rumble values after disconnection.
    ready = NO; deviceInfo.ready = 0; stopMask = 0; dirty = NO;
    memset(&latestMotion, 0, sizeof latestMotion);
    ns2_decode_report09_accessories(NULL, 0, &deviceInfo);
    memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
    pthread_mutex_unlock(&stateMu);
}
static int32_t calibrated_axis(unsigned raw, ns2_calibration cal, unsigned axis) {
    int delta = (int)raw - (int)cal.center[axis];
    double normalized = (double)delta / (delta >= 0 ? cal.above[axis] : cal.below[axis]);
    // 明示 8% 的宿主死区，工厂中心和正负量程分别缩放；不自动学习玩家当前偏转。
    // Use an explicit 8% host deadzone with factory center and separate extents; never learn a held stick as neutral.
    double magnitude = fmin(1.0, fabs(normalized));
    return magnitude <= .08 ? 0 : (int32_t)(copysign((magnitude - .08) / .92, normalized) * NS2_STICK_MAX);
}

@interface NS2Bridge : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate> {
    CBCentralManager *central;
    CBPeripheral *device;
    CBCharacteristic *input, *power, *vibration, *command, *response;
    NSMutableDictionary<NSUUID *, NSNumber *> *retryAfter;
    dispatch_source_t timer;
    ns2_calibration calibration[2];
    NSUInteger step;
    NSData *pendingCommand;
    BOOL awaitingAck, subscribedResponse, streamReady, sessionFailed, preferReport09;
    uint64_t deadline, lastRumble, reports, reports09, rumblePackets;
    uint8_t sequence;
}
- (void)tick;
- (void)scan;
- (void)fail:(NSString *)reason;
- (void)stop;
- (void)resetLink;
- (void)dispose;
- (void)telemetryFailed:(NSString *)reason;
- (void)publishInput:(NSData *)data report:(unsigned)reportID;
@end
static NS2Bridge *bridge;

@implementation NS2Bridge
- (instancetype)init {
    if ((self = [super init])) {
        retryAfter = [NSMutableDictionary new];
        central = [[CBCentralManager alloc] initWithDelegate:self queue:bleQueue options:nil];
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, bleQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 15 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        __weak NS2Bridge *weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { [weakSelf tick]; } });
        dispatch_resume(timer);
    }
    return self;
}
- (void)scan {
    if (self != bridge) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!stopped && !device && central.state == CBManagerStatePoweredOn) {
        [central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];
        emit_status(NS2_STATUS_SCANNING, NS2Localized(@"Searching for a Switch 2 Pro in pairing mode"));
    }
}
- (void)dispose {
    disposing = YES;
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    [central stopScan];
    if (device) { device.delegate = nil; [central cancelPeripheralConnection:device]; }
    central.delegate = nil;
    [self resetLink];
    emit_status(NS2_STATUS_STOPPED, NS2Localized(@"Connection stopped"));
    disposing = NO;
}
- (void)resetLink {
    // 连接级状态必须整体失效；蓝牙断电后的旧 disconnect 回调可能不再匹配 device。
    // Invalidate all link state; after radio power loss the old disconnect callback may no longer match device.
    reset_state(); device = nil; input = power = vibration = command = response = nil;
    pthread_mutex_lock(&stateMu); memset(&deviceInfo, 0, sizeof deviceInfo); pthread_mutex_unlock(&stateMu);
    pendingCommand = nil; awaitingAck = subscribedResponse = streamReady = sessionFailed = preferReport09 = NO;
    deadline = lastRumble = reports = reports09 = rumblePackets = 0; step = 0; sequence = 0;
    memset(calibration, 0, sizeof calibration);
    emit_state((ns2_state){0});
}
- (void)stop {
    [central stopScan];
    if (device && !streamReady) [central cancelPeripheralConnection:device];
    [self tick];
}
- (void)fail:(NSString *)reason {
    LOG("【红】NS2 Pro BLE：%s", reason.UTF8String);
    reset_state(); sessionFailed = YES; streamReady = NO; pendingCommand = nil; awaitingAck = NO; deadline = 0;
    emit_state((ns2_state){0});
    if (self != bridge) return;
    emit_status(NS2_STATUS_ERROR, reason);
    if (self != bridge) return;
    // 暂时失败显式报错并限速重试，不把一次 ACK 超时变成进程内永久封禁。
    // Report transient failures and rate-limit retries instead of permanently rejecting a device after one ACK timeout.
    if (device) { retryAfter[device.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [central cancelPeripheralConnection:device]; }
}
- (void)telemetryFailed:(NSString *)reason {
    LOG("【红】NS2 Pro BLE 电量遥测：%s", reason.UTF8String);
    pthread_mutex_lock(&stateMu);
    ns2_decode_report09_telemetry(NULL, 0, &deviceInfo);
    ns2_decode_report09_accessories(NULL, 0, &deviceInfo);
    snprintf(deviceInfo.telemetry_error, sizeof deviceInfo.telemetry_error, "%s", reason.UTF8String);
    pthread_mutex_unlock(&stateMu);
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager {
    if (self != bridge) return;
    LOG("NS2 Pro BLE Bluetooth state=%ld", (long)manager.state);
    if (manager.state == CBManagerStatePoweredOn) { [self scan]; return; }
    if (manager.state != CBManagerStateUnknown) {
        LOG("【红】NS2 Pro BLE 不可用 state=%ld（检查蓝牙电源和应用蓝牙权限）", (long)manager.state);
        [self resetLink]; [retryAfter removeAllObjects];
        if (self != bridge) return;
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:NS2Localized(@"Bluetooth unavailable (state %ld). Check Bluetooth power and permission."), (long)manager.state]);
    }
}
- (void)centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary<NSString *, id> *)advertisement RSSI:(NSNumber *)rssi {
    if (self != bridge || device || retryAfter[peripheral.identifier].unsignedLongLongValue > now_ns()) return;
    NSData *manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey];
    const uint8_t *m = manufacturer.bytes;
    BOOL pro = manufacturer.length >= 9 && m[0] == 0x53 && m[1] == 0x05 &&
        m[5] == 0x7e && m[6] == 0x05 && m[7] == 0x69 && m[8] == 0x20;
    // 无名称模糊匹配；若广播显式携带 Pro 专属 UUID，也可作为身份依据。
    // Never match names heuristically; an explicitly advertised Pro-only UUID is also identity evidence.
    for (CBUUID *uuid in advertisement[CBAdvertisementDataServiceUUIDsKey]) pro |= uuid_is(uuid, vibrationUUID);
    if (!pro) return;
    [retryAfter removeObjectForKey:peripheral.identifier];
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) return;
    // 断线后的异步 stop 可能晚于 resetLink；新连接握手前丢弃旧 mailbox，避免截断新固件样本。
    // A disconnect's asynchronous stop may follow resetLink; discard the old mailbox before a new handshake so it cannot cut off the new firmware sample.
    reset_state();
    device = peripheral; device.delegate = self; sessionFailed = NO; [manager stopScan];
    pthread_mutex_lock(&stateMu);
    memset(&deviceInfo, 0, sizeof deviceInfo);
    NSString *name = peripheral.name ?: advertisement[CBAdvertisementDataLocalNameKey];
    if (name && ![name getCString:deviceInfo.name maxLength:sizeof deviceInfo.name encoding:NSUTF8StringEncoding])
        memset(deviceInfo.name, 0, sizeof deviceInfo.name);
    [peripheral.identifier.UUIDString getCString:deviceInfo.identifier maxLength:sizeof deviceInfo.identifier encoding:NSUTF8StringEncoding];
    // CoreBluetooth 用 127 表示不可用 RSSI；发现值不代表持续更新的信号强度。
    // CoreBluetooth uses 127 for unavailable RSSI; a discovery value is not a continuously updated signal reading.
    if (rssi && rssi.intValue != 127) { deviceInfo.rssi_known = 1; deviceInfo.rssi_dbm = rssi.intValue; }
    pthread_mutex_unlock(&stateMu);
    deadline = now_ns() + 5ull * NSEC_PER_SEC;
    LOG("NS2 Pro BLE 发现 Pro VID=057E PID=2069 id=%s RSSI=%d", peripheral.identifier.UUIDString.UTF8String, rssi.intValue);
    [manager connectPeripheral:peripheral options:nil];
    emit_status(NS2_STATUS_CONNECTING, NS2Localized(@"Connecting to Switch 2 Pro"));
}
- (void)centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self != bridge || peripheral != device) return;
    pthread_mutex_lock(&stateMu); deviceInfo.connected = 1; pthread_mutex_unlock(&stateMu);
    [peripheral discoverServices:@[[CBUUID UUIDWithString:serviceUUID]]];
    emit_status(NS2_STATUS_INITIALIZING, NS2Localized(@"Reading factory calibration and initializing rumble and player lights"));
}
- (void)centralManager:(CBCentralManager *)manager didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    LOG("【红】NS2 Pro BLE 连接失败：%s", error.localizedDescription.UTF8String ?: "未提供错误详情");
    retryAfter[peripheral.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_ERROR, error.localizedDescription ?: NS2Localized(@"Connection failed")); [self scan];
}
- (void)centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    LOG("%sNS2 Pro BLE 断开：%s；输入和震动状态已丢弃", error ? "【红】" : "", error.localizedDescription.UTF8String ?: "连接结束");
    [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_DISCONNECTED, error.localizedDescription ?: NS2Localized(@"Controller disconnected")); [self scan];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Service discovery failed: %@"), error.localizedDescription]]; return; }
    for (CBService *service in peripheral.services) if (uuid_is(service.UUID, serviceUUID)) {
        [peripheral discoverCharacteristics:nil forService:service]; return;
    }
    [self fail:NS2Localized(@"Nintendo service not found")];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self != bridge || peripheral != device || !uuid_is(service.UUID, serviceUUID)) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Characteristic discovery failed: %@"), error.localizedDescription]]; return; }
    for (CBCharacteristic *ch in service.characteristics) {
        if (uuid_is(ch.UUID, inputUUID)) input = ch;
        if (uuid_is(ch.UUID, powerUUID)) power = ch;
        if (uuid_is(ch.UUID, vibrationUUID)) vibration = ch;
        if (uuid_is(ch.UUID, commandUUID)) command = ch;
        if (uuid_is(ch.UUID, responseUUID)) response = ch;
    }
    if (!input || !(input.properties & CBCharacteristicPropertyNotify) ||
        !response || !(response.properties & CBCharacteristicPropertyNotify) ||
        !command || !(command.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
        !vibration || !(vibration.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        [self fail:NS2Localized(@"The Pro rumble characteristic or required input/command properties are missing")]; return;
    }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] < 42) {
        [self fail:NS2Localized(@"BLE writes without response support fewer than 42 bytes. Rumble reports cannot be split.")]; return;
    }
    [peripheral setNotifyValue:YES forCharacteristic:response];
}
- (NSData *)commandForStep {
    uint8_t bytes[28] = {0, 0x91, 1, 0, 0, 0, 0, 0}; size_t length = 8;
    switch (step) {
        case 0: bytes[0] = 7; bytes[3] = 1; break;
        case 1: case 2:
            bytes[0] = 2; bytes[3] = 4; bytes[5] = 8; length = 16;
            bytes[8] = 0x40; bytes[9] = 0x7e; bytes[12] = step == 1 ? 0x80 : 0xc0; bytes[13] = 0x30; bytes[14] = 1; break;
        case 3: bytes[0] = 3; bytes[3] = 0x0a; bytes[5] = 4; bytes[8] = 5; length = 12; break;
        case 4: bytes[0] = 0x0c; bytes[3] = 2; bytes[5] = 4; bytes[8] = motionCallback ? 0x2f : 0x2b; length = 12; break;
        case 5: {
            bytes[0] = 0x0a; bytes[3] = 8; bytes[5] = 20; length = 28;
            bytes[8] = 1; memset(bytes + 9, 0xff, 8); bytes[17] = 0x35; bytes[19] = 0x46; break;
        }
        case 6: bytes[0] = 0x0c; bytes[3] = 4; bytes[5] = 4; bytes[8] = motionCallback ? 0x2f : 0x2b; length = 12; break;
        // 玩家1常亮；采用已公开且在冷启动有效的 09/07 bitmask 命令。
        // Player1 steady light, using the documented 09/07 bitmask command that works on cold start.
        case 7: bytes[0] = 9; bytes[3] = 7; bytes[5] = 8; bytes[8] = 1; length = 16; break;
        // 固件内置连接样本，与主机记录及 WaveBird 的 0A/02 sample 3 一致。
        // Play firmware connection sample 3 (0A/02), documented in console traces and WaveBird.
        case 8: bytes[0] = 0x0a; bytes[3] = 2; bytes[5] = 4; bytes[8] = 3; length = 12; break;
        default: return nil;
    }
    return [NSData dataWithBytes:bytes length:length];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) { [central cancelPeripheralConnection:peripheral]; return; }
    if (ch == power) {
        if (error || !ch.isNotifying) {
            preferReport09 = NO;
            [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 subscription failed: %@"), error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]];
        }
        return;
    }
    if (error || !ch.isNotifying) { [self fail:[NSString stringWithFormat:NS2Localized(@"Subscription to %@ failed: %@"), ch.UUID, error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]]; return; }
    if (ch == response) { subscribedResponse = YES; deadline = 0; [self tick]; }
    if (ch == input) {
        streamReady = YES; deadline = 0;
        // 不主动覆盖刚播放的固件连接样本；真实停止请求仍通过 mailbox 处理。
        // Do not overwrite the firmware connection sample; actual stop requests still use the mailbox.
        pthread_mutex_lock(&stateMu); ready = YES; deviceInfo.ready = 1; pthread_mutex_unlock(&stateMu);
        LOG("NS2 Pro BLE ready：工厂摇杆校准；report05；玩家1灯命令已确认；双侧双频42-byte震动，15ms周期；gain=%.3g（绝对力度未与主机校准）", rumbleGain);
        emit_status(NS2_STATUS_READY, NS2Localized(@"Connected: factory calibration and player 1 light initialization complete"));
        if (self != bridge) return;
        // report09 订阅可能切断 report05；IMU 模式只用公开可解码的 report05。
        // Subscribing to report09 may cut off report05; IMU mode uses only the publicly decoded report05.
        if (power && !motionCallback) {
            if (power.properties & CBCharacteristicPropertyNotify) [peripheral setNotifyValue:YES forCharacteristic:power];
            else [self telemetryFailed:NS2Localized(@"Report09 does not support notifications. Battery level and charging status are unavailable.")];
        }
        [self tick];
    }
}
- (void)receiveAck:(NSData *)data {
    if (!awaitingAck || data.length < 8) return;
    const uint8_t *p = data.bytes, *request = pendingCommand.bytes;
    if (p[0] != request[0] || p[3] != request[3]) return;
    if (p[1] != 1 || p[2] != 1 || (p[5] & 0x7f) != 0x78) { [self fail:NS2Localized(@"Invalid command response direction, transport or acknowledgement")]; return; }
    if (step == 1 || step == 2) {
        if (data.length < 80 || le32(p + 8) != 0x40 || le32(p + 12) != le32(request + 12)) {
            [self fail:NS2Localized(@"The factory calibration response length or read address does not match")]; return;
        }
        ns2_calibration *cal = &calibration[step - 1]; const uint8_t *record = p + 16 + 0x28;
        unpack12(record, cal->center); unpack12(record + 3, cal->above); unpack12(record + 6, cal->below);
        for (unsigned axis = 0; axis < 2; axis++) if (!cal->center[axis] || !cal->above[axis] || !cal->below[axis] ||
            cal->center[axis] + cal->above[axis] > 4095 || cal->below[axis] > cal->center[axis]) {
            [self fail:NS2Localized(@"Factory stick calibration is invalid. Estimated centers and ranges are not used.")]; return;
        }
        LOG("NS2 Pro BLE calibration side=%lu center=%u,%u above=%u,%u below=%u,%u", (unsigned long)step - 1,
            cal->center[0], cal->center[1], cal->above[0], cal->above[1], cal->below[0], cal->below[1]);
    }
    LOG("NS2 Pro BLE ACK step=%lu cmd=%02x/%02x len=%lu", (unsigned long)step, p[0], p[3], (unsigned long)data.length);
    step++; awaitingAck = NO; pendingCommand = nil; deadline = 0;
    if (step == 9) { deadline = now_ns() + NSEC_PER_SEC; [device setNotifyValue:YES forCharacteristic:input]; }
    else [self tick];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    // 开启 report09 后部分固件只持续发送此通道；必须同时解析它的真实输入布局。
    // Some firmware streams only report09 after subscription, so its actual input layout must also be decoded.
    if (ch == power) {
        if (error) { preferReport09 = NO; [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 notification read failed: %@"), error.localizedDescription]]; return; }
        NSData *powerData = ch.value;
        pthread_mutex_lock(&stateMu);
        int valid = ns2_decode_report09_telemetry(powerData.bytes, powerData.length, &deviceInfo);
        ns2_decode_report09_accessories(powerData.bytes, powerData.length, &deviceInfo);
        if (valid) memset(deviceInfo.telemetry_error, 0, sizeof deviceInfo.telemetry_error);
        pthread_mutex_unlock(&stateMu);
        if (!valid) [self telemetryFailed:NS2Localized(@"Report09 is shorter than 63 bytes or its battery level is outside 0..9")];
        if (streamReady) [self publishInput:powerData report:9];
        return;
    }
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Notification read failed: %@"), error.localizedDescription]]; return; }
    NSData *data = ch.value;
    if (!data) { [self fail:NS2Localized(@"Notification data is empty")]; return; }
    if (ch == response) { [self receiveAck:data]; return; }
    if (ch != input || !streamReady) return;
    if (data.length < 63) { [self fail:[NSString stringWithFormat:NS2Localized(@"Report05 has %lu bytes; at least 63 are required"), (unsigned long)data.length]]; return; }
    pthread_mutex_lock(&stateMu);
    int valid = ns2_decode_report05_telemetry(data.bytes, data.length, &deviceInfo);
    ns2_decode_report05_accessories(data.bytes, data.length, &deviceInfo);
    ns2_motion motion = {0};
    BOOL publishMotion = motionCallback && active && ready && !terminal;
    if (publishMotion && ns2_decode_report05_motion(data.bytes, data.length, &motion)) {
        // 部分固件的设备时钟不可靠；对外用接收时的单调时钟，设备值保留用于诊断。
        // Some firmware has unreliable device timestamps; export monotonic arrival time and retain the device value for diagnostics.
        motion.host_timestamp_us = now_ns() / 1000;
        latestMotion = motion;
    }
    pthread_mutex_unlock(&stateMu);
    if (publishMotion && motion.known) motionCallback(&motion, callbackContext);
    if (self != bridge) return;
    if (!valid) {
        [self fail:NS2Localized(@"Report05 battery fields could not be decoded")]; return;
    }
    if (!preferReport09) [self publishInput:data report:5];
}
- (void)publishInput:(NSData *)data report:(unsigned)reportID {
    ns2_raw_input decoded;
    if (!ns2_decode_input_report(reportID, data.bytes, data.length, &decoded)) {
        [self fail:[NSString stringWithFormat:NS2Localized(@"Report%02x input has %lu bytes; at least 63 are required"), reportID, (unsigned long)data.length]]; return;
    }
    if (reportID == 9 && !preferReport09) {
        preferReport09 = YES;
        LOG("NS2 Pro BLE input source=report09；report05仅更新电压，避免重复输入");
    }
    uint64_t count = reportID == 9 ? ++reports09 : ++reports;
    if (count == 1 || count % 350 == 0)
        LOG("NS2 Pro BLE input report=%02x n=%llu len=%lu buttons=%llx raw=%u,%u,%u,%u",
            reportID, (unsigned long long)count, (unsigned long)data.length, (unsigned long long)decoded.buttons,
            decoded.lx, decoded.ly, decoded.rx, decoded.ry);
    // 回调在锁外调用，允许调用者在回调内停止或读取能力。
    // Invoke callbacks outside the mutex so callers may stop or query capabilities from a callback.
    pthread_mutex_lock(&stateMu);
    BOOL publish = active && ready && !terminal;
    pthread_mutex_unlock(&stateMu);
    if (publish) emit_state((ns2_state){decoded.buttons,
        calibrated_axis(decoded.lx, calibration[0], 0), calibrated_axis(decoded.ly, calibration[0], 1),
        calibrated_axis(decoded.rx, calibration[1], 0), calibrated_axis(decoded.ry, calibration[1], 1)});
}
- (void)tick {
    if (self != bridge) return;
    uint64_t now = now_ns();
    if (sessionFailed) return;
    if (deadline && now >= deadline) { [self fail:awaitingAck ? NS2Localized(@"Initialization command acknowledgement timed out") : NS2Localized(@"Connection, discovery or subscription timed out")]; return; }
    if (!device || device.state != CBPeripheralStateConnected) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!streamReady) {
        if (stopped || !subscribedResponse || awaitingAck || step >= 9) return;
        if (!pendingCommand) { pendingCommand = [self commandForStep]; deadline = now + NSEC_PER_SEC; }
        if (!device.canSendWriteWithoutResponse) return;
        [device writeValue:pendingCommand forCharacteristic:command type:CBCharacteristicWriteWithoutResponse];
        awaitingAck = YES; deadline = now + NSEC_PER_SEC; return;
    }
    if (!device.canSendWriteWithoutResponse) return;
    pthread_mutex_lock(&stateMu);
    // 独立于菜单主线程检查租约，防止界面阻塞时重复旧震动。
    // Enforce leases independently of the UI thread so a stalled menu cannot repeat stale rumble.
    for (unsigned side = 0; side < 2; side++) {
        if (value_nonzero(wanted[side]) && now >= wantedDeadline[side]) {
            wanted[side] = (ns2_vibration){0}; stopMask |= 1u << side; dirty = YES;
        }
    }
    BOOL urgent = stopMask != 0 || (terminal && !shutdownSent);
    BOOL repeating = value_nonzero(wanted[0]) || value_nonzero(wanted[1]);
    // 周期 timer 允许 1ms 调度抖动，避免 14.9ms 的唤醒被跳过后退化为 30ms。
    // Allow 1ms of timer jitter so a 14.9ms wakeup cannot halve the nominal 15ms cadence.
    if ((!dirty && !urgent && !repeating) || (!urgent && now - lastRumble < 14 * NSEC_PER_MSEC)) {
        pthread_mutex_unlock(&stateMu); return;
    }
    ns2_vibration values[2]; memcpy(values, wanted, sizeof values);
    unsigned stopping = stopMask;
    for (unsigned side = 0; side < 2; side++) if ((stopping & (1u << side)) || !active || terminal) values[side] = (ns2_vibration){0};
    uint8_t packet[42]; ns2_encode_rumble(values, sequence, rumbleGain, packet);
    [device writeValue:[NSData dataWithBytes:packet length:sizeof packet] forCharacteristic:vibration type:CBCharacteristicWriteWithoutResponse];
    if ((value_nonzero(values[0]) || value_nonzero(values[1])) && (++rumblePackets == 1 || rumblePackets % 64 == 0))
        LOG("NS2 Pro BLE rumble n=%llu L=%.4f@%.2f/%.4f@%.2f R=%.4f@%.2f/%.4f@%.2f seq=%u（传输提交，非电机遥测）",
            (unsigned long long)rumblePackets, values[0].low_amp, values[0].low_freq, values[0].high_amp, values[0].high_freq,
            values[1].low_amp, values[1].low_freq, values[1].high_amp, values[1].high_freq, sequence & 15);
    memcpy(actual, values, sizeof actual); sequence++; lastRumble = now; stopMask = 0;
    dirty = stopping && (memcmp(values, wanted, sizeof values) != 0);
    BOOL signal = terminal && !shutdownSent;
    if (signal) shutdownSent = YES;
    pthread_mutex_unlock(&stateMu);
    if (signal) {
        LOG("NS2 Pro BLE shutdown：42-byte零包已交给 CoreBluetooth（无硬件ACK）");
        dispatch_group_leave(shutdownGroup);
    }
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral { if (peripheral == device) [self tick]; }
@end

int ns2_start(ns2_state_callback state, ns2_status_callback status, void *context) {
    return ns2_start_with_motion(state, status, NULL, context);
}
int ns2_start_with_motion(ns2_state_callback state, ns2_status_callback status, ns2_motion_callback motion, void *context) {
    __block int accepted = 0;
    on_queue(^{
        if (bridge) return;
        float gainValue = 2;
        const char *gain = getenv("NS2PRO_RUMBLE_GAIN");
        if (gain) {
            char *end; errno = 0; double parsed = strtod(gain, &end);
            if (!*gain || isspace((unsigned char)*gain) || end == gain || *end || errno || !isfinite(parsed) || parsed < 0 || parsed > 4) {
                LOG("【红】NS2PRO_RUMBLE_GAIN 必须为有限数值 0..4");
                return;
            }
            gainValue = (float)parsed;
        }
        stateCallback = state; statusCallback = status; motionCallback = motion; callbackContext = context;
        pthread_mutex_lock(&stateMu);
        terminal = NO; active = YES; ready = NO; dirty = NO; shutdownSent = NO; stopMask = 0;
        memset(&deviceInfo, 0, sizeof deviceInfo);
        memset(&latestMotion, 0, sizeof latestMotion);
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual); rumbleGain = gainValue;
        pthread_mutex_unlock(&stateMu);
        shutdownGroup = dispatch_group_create();
        bridge = [NS2Bridge new];
        accepted = 1;
    });
    return accepted;
}
void ns2_set_active(int enabled) {
    on_queue(^{
        pthread_mutex_lock(&stateMu);
        BOOL next = enabled && !terminal;
        BOOL changed = active != next;
        active = next;
        if (changed) {
            memset(&latestMotion, 0, sizeof latestMotion);
            memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
            stopMask = 3; dirty = YES;
        }
        pthread_mutex_unlock(&stateMu);
        if (changed) { emit_state((ns2_state){0}); [bridge tick]; }
    });
}
unsigned ns2_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && active && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
unsigned ns2_device_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
void ns2_send(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq) {
    ns2_send_lease(side, low_amp, low_freq, high_amp, high_freq, 1000);
}
void ns2_send_lease(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq, unsigned duration_ms) {
    if (side > 1) return;
    ns2_vibration bounded = {low_amp, low_freq, high_amp, high_freq};
    if (!isfinite(low_amp) || !isfinite(high_amp) || !isfinite(low_freq) || !isfinite(high_freq)) {
        LOG("【红】NS2 Pro BLE 拒绝非有限震动值并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    } else if ((low_amp > 0 && low_freq <= 0) || (high_amp > 0 && high_freq <= 0)) {
        LOG("【红】NS2 Pro BLE 拒绝非正载频并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    }
    bounded.low_amp = fminf(1, fmaxf(0, bounded.low_amp));
    bounded.high_amp = fminf(1, fmaxf(0, bounded.high_amp));
    bounded.low_freq = bounded.low_amp ? fminf(1252, fmaxf(40, bounded.low_freq)) : 0;
    bounded.high_freq = bounded.high_amp ? fminf(1252, fmaxf(40, bounded.high_freq)) : 0;
    if (!duration_ms) bounded = (ns2_vibration){0};
    if (duration_ms > 1000) duration_ms = 1000;
    pthread_mutex_lock(&stateMu);
    if (ready && active && !terminal) {
        wanted[side] = bounded; dirty = YES;
        wantedDeadline[side] = now_ns() + (uint64_t)duration_ms * NSEC_PER_MSEC;
        if (!value_nonzero(bounded)) stopMask |= 1u << side;
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_actual(unsigned side, ns2_vibration *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = side < 2 ? actual[side] : (ns2_vibration){0}; pthread_mutex_unlock(&stateMu);
}
void ns2_get_info(ns2_info *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = deviceInfo; pthread_mutex_unlock(&stateMu);
}
void ns2_get_motion(ns2_motion *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu);
    *out = latestMotion;
    if (!ready || !active || terminal || now_ns() / 1000 - out->host_timestamp_us > 250000)
        memset(out, 0, sizeof *out);
    pthread_mutex_unlock(&stateMu);
}
void ns2_stop_rumble(void) {
    pthread_mutex_lock(&stateMu);
    memset(wanted, 0, sizeof wanted); stopMask = 3; dirty = YES;
    pthread_mutex_unlock(&stateMu);
    on_queue(^{ [bridge tick]; });
}
int ns2_shutdown(const char *reason, unsigned timeout_ms) {
    __block NS2Bridge *target;
    __block dispatch_group_t group;
    __block BOOL connected;
    on_queue(^{
        target = disposing ? nil : bridge;
        if (!target) return;
        pthread_mutex_lock(&stateMu);
        connected = ready;
        if (!terminal && connected) dispatch_group_enter(shutdownGroup);
        terminal = YES; active = NO; deviceInfo.ready = 0; stopMask = 3; dirty = YES;
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
        pthread_mutex_unlock(&stateMu);
        group = shutdownGroup;
        [target stop];
    });
    if (!target) return 1;
    long pending = connected ? dispatch_group_wait(group, dispatch_get_specific(&queueKey) ? DISPATCH_TIME_NOW :
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC)) : 0;
    on_queue(^{
        if (target != bridge) return;
        [target dispose]; bridge = nil;
        stateCallback = NULL; statusCallback = NULL; motionCallback = NULL; callbackContext = NULL;
    });
    LOG("%sNS2 Pro BLE shutdown reason=%s result=%s（仅传输提交，非物理电机确认）", pending ? "【红】" : "", reason ?: "unknown", pending ? "timeout" : "submitted");
    return !pending;
}
