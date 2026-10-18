# 本机双频接口 v1

应用显式连接且启用“双频接口”后，绑定 Unix datagram socket：

```
~/.ns2pro-bridge/haptics.sock
```

目录权限 0700，socket 0600。每个数据报是一份 UTF-8 JSON，最多 2048 字节；使用标准 JSONDecoder 解码。没有网络监听、认证令牌或文件队列。应用仅允许当前用户拥有的安全目录和端点；进程锁用于区分运行中的实例和崩溃遗留端点。

```json
{
  "version": 1,
  "durationMilliseconds": 200,
  "left": {
    "lowAmplitude": 0.15,
    "lowFrequency": 160,
    "highAmplitude": 0.1,
    "highFrequency": 320
  },
  "right": {
    "lowAmplitude": 0.15,
    "lowFrequency": 160,
    "highAmplitude": 0.1,
    "highFrequency": 320
  }
}
```

- 幅度为有限数值 0..1；频率为有限数值 40..1252Hz。幅度为零也必须提供有效频率。
- `durationMilliseconds` 是 0..1000 的整数。0 立即停止；正值更新两侧并设置有效期。持续效果建议每 50ms 发一帧，使用 200ms 租约。
- 每帧完整替换两侧。到期停止；客户端崩溃或关闭后无需额外通知，最多持续到最后一帧到期。
- 有效的双频租约期间，普通 Xbox 震动被丢弃。租约结束后，只接受后续新普通命令，不重播抢占前的效果。
- 多个同用户客户端写同一 socket 时，最后接收的有效帧生效；没有跨客户端混音或独占所有权。
- 无效帧不会更新租约，并会停止当前物理震动、显示错误。未连接时帧不会缓存到下一次连接。
- 发送成功仅表示内核接收数据报，不能证明电机执行；接口无硬件 ACK 或回执。应用状态和实机测试是独立验收步骤。

编码保持两侧低/高频独立，频码为 `round(1 + 96 * log2(hz / 10))`，幅码为 `round(192 * gain * amplitude)`，gain 默认 2。频率映射来自之前的本地声学测量，已测范围约 50..640Hz；协议允许的更宽范围尚未逐点测量。不要据此宣称与 Switch 真机完全一致。

发送端示例见 [tools/haptics.py](../tools/haptics.py)，仅使用 Python 标准库。普通游戏需通过其手柄/震动 API；若要保留四组参数，需要游戏或模拟器主动调用本接口。
