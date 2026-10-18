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
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static NSString *const serviceUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0";
static NSString *const inputUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2";
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
static ns2_state_callback stateCallback;
static ns2_status_callback statusCallback;
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
    ready = NO; stopMask = 0; dirty = NO;
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
    CBCharacteristic *input, *vibration, *command, *response;
    NSMutableDictionary<NSUUID *, NSNumber *> *retryAfter;
    dispatch_source_t timer;
    ns2_calibration calibration[2];
    NSUInteger step;
    NSData *pendingCommand;
    BOOL awaitingAck, subscribedResponse, streamReady, sessionFailed;
    uint64_t deadline, lastRumble, reports, rumblePackets;
    uint8_t sequence;
}
- (void)tick;
- (void)scan;
- (void)fail:(NSString *)reason;
- (void)stop;
- (void)resetLink;
- (void)dispose;
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
        emit_status(NS2_STATUS_SCANNING, @"正在寻找配对模式的 Switch 2 Pro");
    }
}
- (void)dispose {
    disposing = YES;
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    [central stopScan];
    if (device) { device.delegate = nil; [central cancelPeripheralConnection:device]; }
    central.delegate = nil;
    [self resetLink];
    emit_status(NS2_STATUS_STOPPED, @"连接已停止");
    disposing = NO;
}
- (void)resetLink {
    // 连接级状态必须整体失效；蓝牙断电后的旧 disconnect 回调可能不再匹配 device。
    // Invalidate all link state; after radio power loss the old disconnect callback may no longer match device.
    reset_state(); device = nil; input = vibration = command = response = nil;
    pendingCommand = nil; awaitingAck = subscribedResponse = streamReady = sessionFailed = NO;
    deadline = lastRumble = reports = rumblePackets = 0; step = 0; sequence = 0;
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
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager {
    if (self != bridge) return;
    LOG("NS2 Pro BLE Bluetooth state=%ld", (long)manager.state);
    if (manager.state == CBManagerStatePoweredOn) { [self scan]; return; }
    if (manager.state != CBManagerStateUnknown) {
        LOG("【红】NS2 Pro BLE 不可用 state=%ld（检查蓝牙电源和应用蓝牙权限）", (long)manager.state);
        [self resetLink]; [retryAfter removeAllObjects];
        if (self != bridge) return;
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:@"蓝牙不可用（状态 %ld），请检查蓝牙电源和权限", (long)manager.state]);
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
    device = peripheral; device.delegate = self; sessionFailed = NO; [manager stopScan];
    deadline = now_ns() + 5ull * NSEC_PER_SEC;
    LOG("NS2 Pro BLE 发现 Pro VID=057E PID=2069 id=%s RSSI=%d", peripheral.identifier.UUIDString.UTF8String, rssi.intValue);
    [manager connectPeripheral:peripheral options:nil];
    emit_status(NS2_STATUS_CONNECTING, @"正在连接 Switch 2 Pro");
}
- (void)centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self != bridge || peripheral != device) return;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:serviceUUID]]];
    emit_status(NS2_STATUS_INITIALIZING, @"正在读取工厂校准并初始化震动与玩家灯");
}
- (void)centralManager:(CBCentralManager *)manager didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    LOG("【红】NS2 Pro BLE 连接失败：%s", error.localizedDescription.UTF8String ?: "未提供错误详情");
    retryAfter[peripheral.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_ERROR, error.localizedDescription ?: @"连接失败"); [self scan];
}
- (void)centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    LOG("%sNS2 Pro BLE 断开：%s；输入和震动状态已丢弃", error ? "【红】" : "", error.localizedDescription.UTF8String ?: "连接结束");
    [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_DISCONNECTED, error.localizedDescription ?: @"手柄已断开"); [self scan];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    if (error) { [self fail:[@"服务发现失败：" stringByAppendingString:error.localizedDescription]]; return; }
    for (CBService *service in peripheral.services) if (uuid_is(service.UUID, serviceUUID)) {
        [peripheral discoverCharacteristics:nil forService:service]; return;
    }
    [self fail:@"未发现 Nintendo 服务"];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self != bridge || peripheral != device || !uuid_is(service.UUID, serviceUUID)) return;
    if (error) { [self fail:[@"特征发现失败：" stringByAppendingString:error.localizedDescription]]; return; }
    for (CBCharacteristic *ch in service.characteristics) {
        if (uuid_is(ch.UUID, inputUUID)) input = ch;
        if (uuid_is(ch.UUID, vibrationUUID)) vibration = ch;
        if (uuid_is(ch.UUID, commandUUID)) command = ch;
        if (uuid_is(ch.UUID, responseUUID)) response = ch;
    }
    if (!input || !(input.properties & CBCharacteristicPropertyNotify) ||
        !response || !(response.properties & CBCharacteristicPropertyNotify) ||
        !command || !(command.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
        !vibration || !(vibration.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        [self fail:@"缺少 Pro 专属震动特征或必需的输入/命令特征属性"]; return;
    }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] < 42) {
        [self fail:@"BLE 无响应写入长度不足 42 字节；不拆分震动 report"]; return;
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
        case 4: bytes[0] = 0x0c; bytes[3] = 2; bytes[5] = 4; bytes[8] = 0x2b; length = 12; break;
        case 5: {
            bytes[0] = 0x0a; bytes[3] = 8; bytes[5] = 20; length = 28;
            bytes[8] = 1; memset(bytes + 9, 0xff, 8); bytes[17] = 0x35; bytes[19] = 0x46; break;
        }
        case 6: bytes[0] = 0x0c; bytes[3] = 4; bytes[5] = 4; bytes[8] = 0x2b; length = 12; break;
        // 玩家1常亮；采用已公开且在冷启动有效的 09/07 bitmask 命令。
        // Player1 steady light, using the documented 09/07 bitmask command that works on cold start.
        case 7: bytes[0] = 9; bytes[3] = 7; bytes[5] = 8; bytes[8] = 1; length = 16; break;
        default: return nil;
    }
    return [NSData dataWithBytes:bytes length:length];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) { [central cancelPeripheralConnection:peripheral]; return; }
    if (error || !ch.isNotifying) { [self fail:[NSString stringWithFormat:@"订阅 %@ 失败：%@", ch.UUID, error.localizedDescription ?: @"通知未启用"]]; return; }
    if (ch == response) { subscribedResponse = YES; deadline = 0; [self tick]; }
    if (ch == input) {
        streamReady = YES; deadline = 0;
        pthread_mutex_lock(&stateMu); ready = YES; stopMask = 3; dirty = YES; pthread_mutex_unlock(&stateMu);
        LOG("NS2 Pro BLE ready：工厂摇杆校准；report05；玩家1灯命令已确认；双侧双频42-byte震动，15ms周期；gain=%.3g（绝对力度未与主机校准）", rumbleGain);
        emit_status(NS2_STATUS_READY, @"已连接：工厂校准与玩家 1 灯初始化完成");
        [self tick];
    }
}
- (void)receiveAck:(NSData *)data {
    if (!awaitingAck || data.length < 8) return;
    const uint8_t *p = data.bytes, *request = pendingCommand.bytes;
    if (p[0] != request[0] || p[3] != request[3]) return;
    if (p[1] != 1 || p[2] != 1 || (p[5] & 0x7f) != 0x78) { [self fail:@"命令响应方向/传输/ACK异常"]; return; }
    if (step == 1 || step == 2) {
        if (data.length < 80 || le32(p + 8) != 0x40 || le32(p + 12) != le32(request + 12)) {
            [self fail:@"工厂校准响应长度或读取地址不匹配"]; return;
        }
        ns2_calibration *cal = &calibration[step - 1]; const uint8_t *record = p + 16 + 0x28;
        unpack12(record, cal->center); unpack12(record + 3, cal->above); unpack12(record + 6, cal->below);
        for (unsigned axis = 0; axis < 2; axis++) if (!cal->center[axis] || !cal->above[axis] || !cal->below[axis] ||
            cal->center[axis] + cal->above[axis] > 4095 || cal->below[axis] > cal->center[axis]) {
            [self fail:@"工厂摇杆校准无效；不使用猜测的中心/量程"]; return;
        }
        LOG("NS2 Pro BLE calibration side=%lu center=%u,%u above=%u,%u below=%u,%u", (unsigned long)step - 1,
            cal->center[0], cal->center[1], cal->above[0], cal->above[1], cal->below[0], cal->below[1]);
    }
    LOG("NS2 Pro BLE ACK step=%lu cmd=%02x/%02x len=%lu", (unsigned long)step, p[0], p[3], (unsigned long)data.length);
    step++; awaitingAck = NO; pendingCommand = nil; deadline = 0;
    if (step == 8) { deadline = now_ns() + NSEC_PER_SEC; [device setNotifyValue:YES forCharacteristic:input]; }
    else [self tick];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    if (error) { [self fail:[@"通知读取失败：" stringByAppendingString:error.localizedDescription]]; return; }
    NSData *data = ch.value;
    if (!data) { [self fail:@"通知数据为空"]; return; }
    if (ch == response) { [self receiveAck:data]; return; }
    if (ch != input || !streamReady) return;
    if (data.length < 63) { [self fail:[NSString stringWithFormat:@"report05长度%lu不足63字节", (unsigned long)data.length]]; return; }
    const uint8_t *p = data.bytes; uint32_t bits = le32(p + 4); unsigned axes[4];
    unpack12(p + 10, axes); unpack12(p + 13, axes + 2);
    if (++reports == 1 || reports % 350 == 0)
        LOG("NS2 Pro BLE input n=%llu len=%lu counter=%u buttons=%08x raw=%u,%u,%u,%u",
            (unsigned long long)reports, (unsigned long)data.length, le32(p), bits, axes[0], axes[1], axes[2], axes[3]);
    static const uint8_t wireBits[21] = {3, 2, 1, 0, 11, 10, 22, 6, 23, 7, 9, 8, 19, 17, 18, 16, 12, 13, 14, 25, 24};
    uint64_t buttons = 0;
    for (unsigned bit = 0; bit < 21; bit++) if (bits & (1u << wireBits[bit])) buttons |= 1ull << bit;
    // 回调在锁外调用，允许调用者在回调内停止或读取能力。
    // Invoke callbacks outside the mutex so callers may stop or query capabilities from a callback.
    pthread_mutex_lock(&stateMu);
    BOOL publish = active && ready && !terminal;
    pthread_mutex_unlock(&stateMu);
    if (publish) emit_state((ns2_state){buttons,
        calibrated_axis(axes[0], calibration[0], 0), calibrated_axis(axes[1], calibration[0], 1),
        calibrated_axis(axes[2], calibration[1], 0), calibrated_axis(axes[3], calibration[1], 1)});
}
- (void)tick {
    if (self != bridge) return;
    uint64_t now = now_ns();
    if (sessionFailed) return;
    if (deadline && now >= deadline) { [self fail:awaitingAck ? @"初始化命令 ACK 超时" : @"连接/发现/订阅超时"]; return; }
    if (!device || device.state != CBPeripheralStateConnected) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!streamReady) {
        if (stopped || !subscribedResponse || awaitingAck || step >= 8) return;
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
        stateCallback = state; statusCallback = status; callbackContext = context;
        pthread_mutex_lock(&stateMu);
        terminal = NO; active = YES; ready = NO; dirty = NO; shutdownSent = NO; stopMask = 0;
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
        terminal = YES; active = NO; stopMask = 3; dirty = YES;
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
        stateCallback = NULL; statusCallback = NULL; callbackContext = NULL;
    });
    LOG("%sNS2 Pro BLE shutdown reason=%s result=%s（仅传输提交，非物理电机确认）", pending ? "【红】" : "", reason ?: "unknown", pending ? "timeout" : "submitted");
    return !pending;
}
