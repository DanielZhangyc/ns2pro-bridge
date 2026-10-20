# 运动与附件

## 运动接口

在设置中启用“向本机应用提供运动数据（DSU）”，再连接手柄。在支持 DSU/Cemuhook 的应用中设置 `127.0.0.1:26760`，选择插槽 0。开关默认关闭；修改前先断开手柄。

服务使用 [DSU 1001 协议](https://github.com/v1993/cemuhook-protocol)：提供版本查询、设备查询与按全部设备、插槽或 MAC 注册。仅绑定 IPv4 loopback，端口冲突直接报错；最多 32 个本机客户端，订阅须在 5 秒内续约。`02:00:00:00:00:01` 是本程序的虚拟标识，不是手柄的蓝牙地址。按键和摇杆继续由现有 Xbox HID 提供，DSU 的按键、触摸保持中立。

每个实际收到的 report05 产生一个运动样本，不插值、不重放历史样本。断开、睡眠与退出清除订阅，发送 inactive 状态；inactive 包中的零值不是传感器采样。接收时间超过 250 ms 的排队样本不发送，诊断窗口也将其标为不可用。

report05 偏移 `0x2A` 的 18 字节包含设备时间、温度、三个加速度轴和三个角速度轴。[公开协议研究](https://github.com/ndeadly/switch2_controller_research/blob/a3306b473acff0d6844fb1e288883a3940df0baf/hid_reports.md#motion-data)给出的默认换算为：

- 加速度：有符号 16 位小端值乘 `8 / 32767`，单位 g。
- 角速度：有符号 16 位小端值乘 `2000 / 32767`，单位 °/s。
- DSU 坐标采用 `(rawX, rawZ, -rawY)`，同时旋转加速度和角速度；角速度三个输出依次为 pitch、yaw、roll。该旋转参照 [SDL 的 Switch 2 驱动固定版本](https://github.com/libsdl-org/SDL/blob/8a1684fbbc8b04c94cdf6b304450c5d941d0cafb/src/joystick/hidapi/SDL_hidapi_switch2.c)。

设备原始时间戳仍保留在 C API 中，DSU 使用接收时的单调时钟，因为已知部分固件的设备时间不可靠。当前没有读取未知格式的工厂 IMU 校准，也没有自动静止学习或传感器融合。默认换算不是用户这只手柄的精度校准。

部分固件订阅 report09 后会停止 report05；report09 的运动块是另一种压缩格式，公开资料尚未完整解释。因此运动模式只订阅 report05，暂不提供 report09 的固件电量等级、充电与 NFC 状态。电压和耳机插入标志仍可从 report05 读取。关闭运动接口可恢复原有 report09 订阅。

可用标准库客户端读取真实数据并检查 CRC、时间递增和统计值：

```sh
python3 tools/dsu-monitor.py --seconds 10
```

`--output /absolute/path/capture.jsonl` 可将实际收包另存到仓库外，文件已存在时拒绝覆盖。该工具不生成运动样本，成功收包也不等于模拟器游戏中的轴向或体验已验证。

## NFC 与耳机

| 能力 | 当前实现 | 尚缺内容 |
| --- | --- | --- |
| 耳机插入 | report05 按键区总 bit 28 | 手柄与固件上的插拔验证 |
| 耳机 / 耳麦分类 | report09 `0x0D`；`05/0D` 耳机、`07/0F` 耳麦，`00` 未连接；其他值保留为未知 | 插入状态的真实抓包与麦克风验证 |
| NFC 状态 | report09 `0x0C` 的 `0..7`；`0` 显示空闲，不推断卡片存在 | 初始化、轮询、UID、读卡与分片状态机 |
| 蓝牙耳机音频 | 尚未实现 | 编码、帧边界、时序、输入输出控制，以及 macOS 音频设备集成 |
| USB 音频 | 不在当前 BLE 传输路径中 | 有线连接后的系统枚举、路由、播放和录音验证 |

依据均为 [ndeadly 的报告布局](https://github.com/ndeadly/switch2_controller_research/blob/a3306b473acff0d6844fb1e288883a3940df0baf/hid_reports.md)。NFC 的[命令表](https://github.com/ndeadly/switch2_controller_research/blob/a3306b473acff0d6844fb1e288883a3940df0baf/commands.md#command-0x01---nfc)记录了 `0x01` 命令及部分读取、缓冲操作，但没有给出完整 BLE 读卡状态机。本实现不重放未知写入或猜测标签数据。

固件 2.0.0+ 的[蓝牙音频特征](https://github.com/ndeadly/switch2_controller_research/blob/a3306b473acff0d6844fb1e288883a3940df0baf/bluetooth_interface.md)已经公开：输出 `cc483f51-9258-427d-a939-630c31f72b06`、输入 `7492866c-ec3e-4619-8258-32755ffcc0f9`。输入在 report09 布局中插入 52 字节音频区，但编码格式仍标为未知，不能作为 PCM 直接播放。

[USB 描述符](https://github.com/ndeadly/switch2_controller_research/blob/a3306b473acff0d6844fb1e288883a3940df0baf/descriptors.md)包含 Audio 1.0、48 kHz、16 位双声道流。它提示可以另行验证 macOS USB Audio 路径，不证明当前主机已经识别或可以与 BLE 同时使用。

## 验证边界

协议回归使用上游真实 pcap 中的 report05 与 report09，来源和帧号在 `MotionAccessoryTests.swift` 中记录。DSU 使用真实本机 UDP 测试版本、CRC、查询、注册、租约与断开清理；这些测试不会创建或冒充物理传感器样本。

真实设备的插拔、运动方向、读卡和播放结果应分别记录。构建成功与本机网络测试不能代替这些证据。

2026-10-19 在用户的单只 Switch 2 Pro 上完成以下检查：

| 检查 | 观察结果 | 证据范围 |
| --- | --- | --- |
| BLE 初始化与 IMU | 9 步初始化均收到 ACK；启用 IMU 后持续收到 63 字节 report05 | 当前设备、当前固件的 BLE 链路 |
| 静放 DSU 采集 | 10.020 秒、325 个真实样本，约 32.3 Hz；平均加速度模长 1.0024 g | CRC、数据格式和单位量级；不是精密校准 |
| 转动响应 | 30.000 秒、958 个真实样本；三个角速度通道均出现明显变化 | 三轴有响应；未完成目标模拟器中的正向验证 |
| 断开清理 | 独立采集收到 163 个样本后收到 1 个 inactive 包；UDP 端口释放；零震动包已提交 CoreBluetooth | 软件停止路径；不是电机硬件 ACK |
| report09 重连 | 关闭运动模式后恢复固件电量、充电与附件状态；显示 NFC 空闲、耳机未插入 | 仅当前无卡片、未插耳机的状态 |

46 项 Swift 测试通过；release app 构建并验证签名。硬件采集构建之后补充了 report09 错误时清除附件状态和异步错误的会话检查，最终构建包含这些修复。用户当时没有耳机或 NFC 道具，因此尚未验证插拔、耳麦分类、读卡或播放；也没有运行模拟器游戏。
