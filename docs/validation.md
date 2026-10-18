# 验证记录

2026-10-18，Apple Silicon 本机，Swift 6.4、macOS 27 SDK、部署目标 macOS 26。

## 开发签名与启动

初次交付把受限 Virtual HID entitlement 加入 ad-hoc 签名，导致用户无法打开。系统 amfid 日志返回 `Code=-424: The file is adhoc signed but contains restricted entitlements`。此前签名完整性检查通过，不能证明应用可以启动；初次验收遗漏了这一点。

构建脚本现已禁止这种组合。没有授权描述文件时，默认构建不携带受限权限，可以打开，但显示“缺少系统手柄授权”并禁用连接。完整模式必须提供 `PROVISIONING_PROFILE` 和对应的 `SIGN_IDENTITY`，脚本先检查 Virtual HID 授权、到期时间及应用标识。

在用户确认后，已通过 Apple 开发者后台注册 App ID、启用 **HID Virtual Device (development)**，登记本机 Mac 并生成匹配的 macOS 开发描述文件。下载后确认描述文件实际授予 `com.apple.developer.hid.virtual.device`，包含本机设备，并用对应 Apple Development 证书签名。受限开发授权可直接配置，不能与正式分发权限审批混为一谈。

28 项测试通过后重新打包，开发签名应用成功启动。当前主页将手柄照片与实时输入合并显示；`⌘,` 已实际打开独立 Settings 窗口。详情整行展开、工具栏连接等待指示及间距已通过截图检查。开发描述文件、设备标识及签名凭据均不提交到仓库。

## 已取得的设备证据

独立 BLE 后端已连接真实 Switch 2 Pro，report05 此前读取到 **3.495 V**。订阅 report09 后，原实现只处理 report05 的首帧输入，导致按键不能持续更新；修复 report09 完整输入解码后，日志连续记录至 `n350`、`n700`。Apple GameController 枚举到 `Xbox Wireless Controller`，`extendedGamepad=true`，探针实际收到 A/B 的 0↔1 和摇杆连续变化，确认了独立应用到系统虚拟手柄的输入路径。用户针对手柄图按键高亮确认“我看过了，没问题了”。这不代表具体游戏已经验收。

report09 已真实显示电量等级 **7/9**、未在充电、电池供电；没有将等级或电压换算为精确百分比。`0A/02` sample 3 原生连接震动已收到命令 ACK，用户确认“感受到了”。充电与供电状态变化仍未专项验证。提取前 BLE 后端的双频震动证据仅作为来源背景，不替代当前应用的普通与双频电机输出验收；绝对力度尚未与 Switch 主机校准。

## 已完成

- `swift test --jobs 2`：28 项 XCTest，全部通过。
- 双频编码：已测频码、左右独立字段、gain、停止包、序号回绕、非法值及边界。
- Xbox 报告：中立输入、按键物理布局、Home/Capture、摇杆/方向/扳机、输出 report ID 有/无前缀、掩码与畸形包。
- 连续输入：report09 完整按键与摇杆解码已修复并测试；Xbox Y 轴按 SDL/WaveBird 的方向约定转换。真实摇杆已有连续变化证据，但向上、向下的方向专项尚未取得用户确认。
- 本机 IPC：真实 Unix datagram 收发、无效 JSON 拒绝、独占锁、实际孤立 socket 恢复、拒绝符号链接且保留目标文件。测试使用独立 `/tmp` 目录，不绑定应用正式地址。
- 遥测：report05 电池电压的低位优先解码、原始充电字节保留、截断报告清除、空闲查询不生成设备连接；report09 电量等级 0–9、充电与外部供电位解码，以及非法等级和截断报告处理。窗口仅在收到有效报告后显示相应状态，不根据电压或等级推算精确百分比。
- `bash scripts/build-app.sh`：Release 编译、`.app` 打包和匹配开发描述文件的签名检查通过。
- Icon Composer 可编辑工程及 SVG，`actool` 实际生成 AppIcon.icns / Assets.car 并装入应用。
- 手柄照片使用任天堂官方 PNG，保留原始画布并叠加输入指示；其版权不属于 MIT，来源与权利见[素材说明](../Resources/Controller/ATTRIBUTION.md)。
- `plutil -lint`：Info.plist 与 entitlement 文件通过。
- `bash -n` 与 Python 编译检查通过；Python 客户端帮助可运行，未向实际手柄发送。
- 源码已去除游戏运行时依赖；无游戏资源、密钥或存档。

连接状态下执行 `⌘Q`，已确认进程退出，日志显示 42 字节零包 `submitted`。这证明停止包交给了 CoreBluetooth，不是电机已停止的遥测回执。

## 尚未验证

以下仍需在游戏结束后验证：

1. 具体 SDL/Steam 游戏中的输入与震动兼容性、Guide/Share 行为，以及摇杆上下方向专项。
2. report09 电量等级、充电与外部供电状态随真实设备变化的情况。
3. 普通震动与本机双频客户端能否驱动实际电机；抢占结束、菜单展开、断线、睡眠、退出时能否停止；重新连接是否会重播旧震动。
4. 普通游戏输出时长与独立应用下的实机触感；绝对幅度与 Switch 真机对比。

macOS 26 实机、Intel、USB 和 iPad/iOS 均无本轮验证。CoreHID 的输出请求数据由客户端决定，代码支持已知 Xbox BLE 长度，但不承诺未知客户端报告变体。未做开发者公证或应用商店发布。

## 停止语义

BLE 队列以单调时钟独立检查最多 1000ms 的物理输出租约，避免主线程阻塞导致重复旧效果；主线程同时管理双频抢占。普通无限时长 HID 命令在调度器中最多维持 5 秒，收到新命令可续约。断开/退出发送停止包并关闭连接；提交成功仅代表 CoreBluetooth 接收，无法证明手柄实际停止。设备/链路故障下的最终状态必须实机检查。
