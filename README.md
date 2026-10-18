# NS2 Pro Bridge

独立的 Nintendo Switch 2 Pro 手柄 macOS 蓝牙适配器。把手柄呈现为系统可识别的 Xbox 手柄，并为支持接入的应用提供左右独立、低/高两组频率的原生震动接口。

这是 **0.1.0 开发版**。蓝牙与双频编码来自已在真实 NS2 Pro 上验证的独立游戏适配路径；本仓库已做编译和离线协议测试。**独立应用的 CoreHID 权限、GameController/SDL 识别、端到端震动及重连尚待实机验收**。当前没有运行应用或切换用户正在使用的手柄。

## 功能与边界

- 系统输入：摇杆、方向键、ABXY、肩键、扳机、摇杆按压、加减、Home、Capture。按物理位置映射：Nintendo B → Xbox A、A → B、Y → X、X → Y；Home → Guide、Capture → Share。系统/游戏可能保留 Guide 或 Share 的用途。
- BLE 连接：工厂摇杆校准、8% 死区、初始化 ACK、玩家 1 常亮灯、掉线重试、断线清空输入。
- 普通游戏震动：接收 Xbox HID 输出，保留左右力度、时长和重复信息。左侧使用 160Hz，右侧使用 320Hz；普通接口没有原始频率，**不能恢复 Switch 原生 HD 波形**。
- 原生双频：本机 Unix datagram 接口传入左右各两组频率/幅度，不合并频带。默认力度 2 倍；此设置此前由用户实测选择，绝对力度未与 Switch 主机校准。
- 停止保护：双频帧最长一秒、普通零时长命令最长五秒；断开、睡眠和退出时清空震动。双频抢占时丢弃旧普通震动，不在结束后重播。
- 单只手柄、蓝牙、macOS 26+。USB、iPad/iOS、陀螺仪、NFC、耳机口、电池 UI、C/GL/GR 自定义映射目前不支持。C/GL/GR 位保留在底层回调中。

“系统通用”指符合虚拟 Xbox HID 路径的应用，不意味着每个游戏都实现震动。需要原始双频的应用必须主动接入 [双频协议](docs/native-haptics.md)；不注入或修改其他游戏进程。

## 构建

需要提供 macOS 26 CoreHID SDK 的 Xcode，以及 Swift 6.2+。当前验证环境是 Apple Silicon、Swift 6.4 / macOS 27 SDK，部署目标 macOS 26。没有第三方包依赖。

```sh
swift test --jobs 2
bash scripts/build-app.sh
```

产物：`dist/NS2 Pro Bridge.app`。脚本只构建并做 ad-hoc 签名，不启动、安装或注册开机自启。可用 `SIGN_IDENTITY` 指定自己的签名身份；默认产物没有公证，不是 App Store 发布包。虚拟 HID entitlement 已写入签名，但实际权限是否获准须在本机运行时验证。

## 使用

1. 保存并结束正在使用手柄的游戏，退出 WaveBird 等其他适配器。若游戏内置了直接连接 NS2 Pro 的后端，应先关闭该后端，避免竞争同一设备。
2. 打开构建的应用；菜单栏出现手柄图标。应用启动时不会自动连接。
3. 选择力度（默认 2 倍），点击“连接手柄”，按系统提示允许蓝牙和虚拟 HID 所需权限；长按手柄顶部 SYNC。
4. 显示“手柄已连接”后，检查玩家灯常亮，再启动支持系统手柄的游戏。系统识别的名称为 `Xbox Wireless Controller`。
5. 使用“断开手柄”释放连接；“退出 NS2 Pro Bridge”或原生退出会执行停止与清理。睡眠会断开，唤醒后手动重新连接。

输入监控是否需要授权取决于系统的 CoreHID 权限流程。若出现权限/签名错误，按实际系统提示处理；不要在运行中的游戏会话里反复启动适配器。

启用双频接口后，地址为 `~/.ns2pro-bridge/haptics.sock`。客户端示例：

```sh
python3 tools/haptics.py --left 0.15 160 0.1 320 --right 0.15 160 0.1 320 --seconds 1
```

该命令会真实驱动已经连接的手柄。首次调试请从较小幅度开始。

## 结构

| 目录 | 用途 |
| --- | --- |
| `Sources/NS2Transport` | ObjC/C BLE、校准、初始化及双频报文编码 |
| `Sources/BridgeApp` | 菜单栏应用、CoreHID 虚拟 Xbox、震动调度、本机 IPC |
| `Tests/BridgeAppTests` | 不连接硬件的编码、边界和本机 socket 测试 |
| `tools/haptics.py` | 标准库 Python 双频客户端 |
| `scripts/build-app.sh` | 本机 `.app` 打包和签名 |

物理断线后虚拟设备保持发布并发送中立输入，便于游戏继续使用同一逻辑手柄。点击断开或退出会撤销虚拟设备。双频接口是同一用户下的“最后一帧生效”接口，不用于不可信的多用户网络服务。

详见 [验证记录](docs/validation.md) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。MIT 许可证；不包含游戏资源、密钥、存档或游戏运行时。
