import Foundation
import Darwin

struct DSUMotionSample: Sendable {
    let timestampMicroseconds: UInt64
    let accelerationX: Float
    let accelerationY: Float
    let accelerationZ: Float
    // 调用方提供 DSU 的 pitch、yaw、roll，依次写入 X、Y、Z；单位为度每秒。
    // The caller maps DSU pitch, yaw, roll into X, Y, Z respectively, in degrees per second.
    let gyroX: Float
    let gyroY: Float
    let gyroZ: Float

    var isFinite: Bool {
        [accelerationX, accelerationY, accelerationZ, gyroX, gyroY, gyroZ].allSatisfy(\.isFinite)
    }
}

enum DSUMotionError: LocalizedError {
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .system(operation, code): L10n.format("%@: %@", L10n.text(operation), String(cString: strerror(code)))
        }
    }
}

enum DSUMotionWire {
    static let version: UInt16 = 1001
    // 本地管理的虚拟标识，仅用于 DSU 稳定识别，不代表硬件 MAC。
    // This locally administered virtual identifier is stable for DSU and is not a hardware MAC.
    static let virtualMAC: [UInt8] = [0x02, 0, 0, 0, 0, 1]

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }

    static func integer<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func read<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int, as: T.Type) -> T {
        bytes[offset..<(offset + MemoryLayout<T>.size)].enumerated().reduce(T.zero) {
            $0 | (T($1.element) << ($1.offset * 8))
        }
    }

    static func packet(type: UInt32, payload: [UInt8], serverID: UInt32) -> [UInt8] {
        var bytes = Array("DSUS".utf8) + integer(version) + integer(UInt16(payload.count + 4))
        bytes += [UInt8](repeating: 0, count: 4) + integer(serverID) + integer(type) + payload
        bytes.replaceSubrange(8..<12, with: integer(crc32(bytes)))
        return bytes
    }

    static func request(_ bytes: [UInt8]) -> (type: UInt32, payload: [UInt8])? {
        guard bytes.count >= 20, bytes.prefix(4).elementsEqual("DSUC".utf8),
              read(bytes, at: 4, as: UInt16.self) == version else { return nil }
        let length = Int(read(bytes, at: 6, as: UInt16.self)) + 16
        guard length >= 20, length <= bytes.count else { return nil }
        var packet = Array(bytes.prefix(length))
        let expected = read(packet, at: 8, as: UInt32.self)
        packet.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        guard crc32(packet) == expected else { return nil }
        return (read(packet, at: 16, as: UInt32.self), Array(packet.dropFirst(20)))
    }
}

@MainActor final class DSUMotionServer {
    private struct Client {
        var address: sockaddr_in
        var renewedAt: TimeInterval
        var packetNumber: UInt32 = 0
    }

    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [UInt16: Client] = [:]
    private var connected = false
    private var lastTimestamp: UInt64?
    private var serverID: UInt32 = 0
    private let onError: (String) -> Void
    private(set) var boundPort: UInt16?

    init(onError: @escaping (String) -> Void) { self.onError = onError }

    isolated deinit { stop() }

    func start(port: UInt16 = 26760) throws {
        guard descriptor == -1 else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DSUMotionError.system("Could not create the motion socket", errno) }
        var accepted = false
        defer { if !accepted { close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw DSUMotionError.system("Could not configure the motion socket", errno)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw DSUMotionError.system("Could not bind the motion port", errno) }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        guard inspected == 0 else { throw DSUMotionError.system("Could not inspect the motion socket", errno) }
        descriptor = fd
        boundPort = UInt16(bigEndian: address.sin_port)
        serverID = UInt32.random(in: UInt32.min...UInt32.max)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.descriptor == fd else { return }
                self.receive()
            }
        }
        readSource.setCancelHandler { close(fd) }
        source = readSource
        accepted = true
        readSource.resume()
    }

    func stop() {
        sendInactive()
        clients.removeAll()
        lastTimestamp = nil
        connected = false
        source?.cancel()
        source = nil
        descriptor = -1
        boundPort = nil
    }

    func setConnected(_ connected: Bool) {
        guard self.connected != connected else { return }
        if !connected {
            sendInactive()
            clients.removeAll()
            lastTimestamp = nil
        }
        self.connected = connected
    }

    func publish(_ sample: DSUMotionSample) {
        guard descriptor >= 0, connected else { return }
        guard sample.isFinite else { onError(L10n.text("Invalid motion sample")); return }
        guard lastTimestamp.map({ sample.timestampMicroseconds > $0 }) ?? true else { return }
        lastTimestamp = sample.timestampMicroseconds
        expireClients()
        // 仅新传感器样本触发数据包；注册和定时器均不重放旧样本。
        // Only a new sensor sample emits data; registration and timers never replay old samples.
        for key in Array(clients.keys) {
            guard var client = clients[key] else { continue }
            client.packetNumber &+= 1
            clients[key] = client
            var payload = dataPrefix(active: true, packetNumber: client.packetNumber)
            payload += DSUMotionWire.integer(sample.timestampMicroseconds)
            for value in [sample.accelerationX, sample.accelerationY, sample.accelerationZ,
                          sample.gyroX, sample.gyroY, sample.gyroZ] {
                payload += DSUMotionWire.integer(value.bitPattern)
            }
            send(type: 0x100002, payload: payload, address: client.address)
        }
    }

    private func expireClients() {
        let now = ProcessInfo.processInfo.systemUptime
        clients = clients.filter { now - $0.value.renewedAt < 5 }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 1025)
        // 限制每轮读取及客户端数量，避免 UDP 流量占满主线程或持续增加内存。
        // Bound each read drain and client count to limit main-thread work and memory use.
        for _ in 0..<32 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                onError(DSUMotionError.system("Could not read the motion socket", errno).localizedDescription)
                stop()
                return
            }
            guard count <= 1024, length == MemoryLayout<sockaddr_in>.size,
                  address.sin_family == AF_INET,
                  address.sin_addr.s_addr == in_addr_t(INADDR_LOOPBACK).bigEndian,
                  let request = DSUMotionWire.request(Array(buffer.prefix(count))) else { continue }
            handle(type: request.type, payload: request.payload, address: address)
        }
    }

    private func handle(type: UInt32, payload: [UInt8], address: sockaddr_in) {
        switch type {
        case 0x100000:
            guard payload.isEmpty else { return }
            send(type: type, payload: DSUMotionWire.integer(DSUMotionWire.version), address: address)
        case 0x100001:
            guard payload.count >= 4 else { return }
            let count = Int(DSUMotionWire.read(payload, at: 0, as: UInt32.self))
            guard (1...4).contains(count), payload.count == 4 + count,
                  payload.dropFirst(4).allSatisfy({ $0 < 4 }) else { return }
            for slot in payload.dropFirst(4) {
                send(type: type, payload: information(slot: slot, active: slot == 0 && connected) + [0], address: address)
            }
        case 0x100002:
            guard connected, payload.count == 8, payload[0] & ~3 == 0 else { return }
            let flags = payload[0]
            guard flags & 1 == 0 || payload[1] < 4 else { return }
            let matches = flags == 0 || (flags & 1 != 0 && payload[1] == 0)
                || (flags & 2 != 0 && payload.suffix(6).elementsEqual(DSUMotionWire.virtualMAC))
            guard matches else { return }
            expireClients()
            let key = address.sin_port
            guard clients[key] != nil || clients.count < 32 else { return }
            var client = clients[key] ?? Client(address: address, renewedAt: 0)
            client.renewedAt = ProcessInfo.processInfo.systemUptime
            clients[key] = client
        default:
            break
        }
    }

    private func information(slot: UInt8, active: Bool) -> [UInt8] {
        guard slot == 0, active else { return [slot] + [UInt8](repeating: 0, count: 10) }
        return [0, 2, 2, 2] + DSUMotionWire.virtualMAC + [0]
    }

    private func dataPrefix(active: Bool, packetNumber: UInt32) -> [UInt8] {
        var bytes = information(slot: 0, active: active) + [active ? 1 : 0]
        bytes += DSUMotionWire.integer(packetNumber)
        bytes += [0, 0, 0, 0, 128, 128, 128, 128]
        bytes += [UInt8](repeating: 0, count: 24)
        return bytes
    }

    private func sendInactive() {
        guard descriptor >= 0 else { return }
        expireClients()
        for client in clients.values {
            // inactive 数据包中的零字段不代表采样，客户端必须按断开标志忽略它们。
            // Zero fields in an inactive packet are not samples; clients must ignore them per the disconnected flag.
            let payload = dataPrefix(active: false, packetNumber: client.packetNumber &+ 1)
                + [UInt8](repeating: 0, count: 32)
            send(type: 0x100002, payload: payload, address: client.address)
        }
    }

    private func send(type: UInt32, payload: [UInt8], address: sockaddr_in) {
        let bytes = DSUMotionWire.packet(type: type, payload: payload, serverID: serverID)
        var target = address
        let count = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            onError(DSUMotionError.system("Could not send motion data", errno).localizedDescription)
        }
    }
}
