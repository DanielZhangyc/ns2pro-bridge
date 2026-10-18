# 验证记录

2026-10-18，Apple Silicon 本机，Swift 6.4、macOS 27 SDK、部署目标 macOS 26。

## 启动缺陷与当前阻塞

初次交付把受限 Virtual HID entitlement 加入 ad-hoc 签名，导致用户无法打开。系统 amfid 日志返回 `Code=-424: The file is adhoc signed but contains restricted entitlements`。此前签名完整性检查通过，不能证明应用可以启动；初次验收遗漏了这一点。

构建脚本现已禁止这种组合。没有授权描述文件时，默认构建不携带受限权限，可以打开，但显示“缺少系统手柄授权”并禁用连接。完整模式必须提供 `PROVISIONING_PROFILE` 和对应的 `SIGN_IDENTITY`，脚本先检查 Virtual HID 授权、到期时间及应用标识。本机现有描述文件均为 iOS，未包含此授权；普通开发者证书本身不能补齐它。

修复后 16 项测试再次通过，Release 重新打包，并更新 `/Applications/NS2 Pro Bridge.app`。`open -g` 成功，后续确认应用进程持续运行。未点击连接、未启动 BLE 或虚拟 HID。启动错误已修复，**替代 WaveBird 的全系统模式仍被 Apple 授权阻塞，不能作为已完成功能交付**。

## 已完成

- `swift test --jobs 2`：16 项 XCTest，全部通过。
- 双频编码：已测频码、左右独立字段、gain、停止包、序号回绕、非法值及边界。
- Xbox 报告：中立输入、按键物理布局、Home/Capture、摇杆/方向/扳机、输出 report ID 有/无前缀、掩码与畸形包。
- 本机 IPC：真实 Unix datagram 收发、无效 JSON 拒绝、独占锁、实际孤立 socket 恢复、拒绝符号链接且保留目标文件。测试使用独立 `/tmp` 目录，不绑定应用正式地址。
- `bash scripts/build-app.sh`：Release 编译、`.app` 打包和 ad-hoc 签名完整性检查通过。
- `plutil -lint`：Info.plist 与 entitlement 文件通过。
- `bash -n` 与 Python 编译检查通过；Python 客户端帮助可运行，未向实际手柄发送。
- 源码已去除游戏运行时依赖；无游戏资源、密钥或存档。

上游提取前的 BLE 后端曾有实机证据：连接输入、玩家灯常亮、低高双频和用户选择的 2 倍力度。本次提取后没有重新连接设备，因此这些证据不能替代独立应用的端到端验收。

## 尚未验证

未激活 CoreHID、扫描蓝牙或切换设备连接。以下仍需在取得授权且游戏结束后验证：

1. 系统是否接受本机签名和虚拟 HID entitlement，蓝牙与相关权限提示是否正常。
2. 独立应用连接后，Apple GameController 和目标 SDL/Steam 游戏是否识别输入、Guide/Share 与普通震动。
3. 本机双频客户端驱动实际电机；抢占结束、菜单展开、断线、睡眠、退出时停止；重新连接没有旧震动重播。
4. 普通游戏输出时长与独立应用下的实机触感；绝对幅度与 Switch 真机对比。

macOS 26 实机、Intel、USB 和 iPad/iOS 均无本轮验证。CoreHID 的输出请求数据由客户端决定，代码支持已知 Xbox BLE 长度，但不承诺未知客户端报告变体。未做开发者公证或应用商店发布。

## 停止语义

BLE 队列以单调时钟独立检查最多 1000ms 的物理输出租约，避免主线程阻塞导致重复旧效果；主线程同时管理双频抢占。普通无限时长 HID 命令在调度器中最多维持 5 秒，收到新命令可续约。断开/退出发送停止包并关闭连接；提交成功仅代表 CoreBluetooth 接收，无法证明手柄实际停止。设备/链路故障下的最终状态必须实机检查。
