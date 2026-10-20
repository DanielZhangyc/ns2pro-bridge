import XCTest
import Darwin
@testable import BridgeApp

final class DSUMotionTests: XCTestCase {
    private func request(_ type: UInt32, _ payload: [UInt8] = [], version: UInt16 = 1001) -> [UInt8] {
        var bytes = Array("DSUC".utf8) + DSUMotionWire.integer(version)
        bytes += DSUMotionWire.integer(UInt16(payload.count + 4)) + [UInt8](repeating: 0, count: 4)
        bytes += DSUMotionWire.integer(UInt32(0x12345678)) + DSUMotionWire.integer(type) + payload
        bytes.replaceSubrange(8..<12, with: DSUMotionWire.integer(DSUMotionWire.crc32(bytes)))
        return bytes
    }

    private func client(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw DSUMotionError.system("Test socket failed", errno) }
        var accepted = false
        defer { if !accepted { close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw DSUMotionError.system("Test socket flags failed", errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw DSUMotionError.system("Test connect failed", errno) }
        accepted = true
        return fd
    }

    private func send(_ bytes: [UInt8], to fd: Int32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }, bytes.count, file: file, line: line)
    }

    @MainActor private func receive(_ fd: Int32, timeout: Duration = .seconds(1)) async throws -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count >= 0 { return Array(bytes.prefix(count)) }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                throw DSUMotionError.system("Test receive failed", errno)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @MainActor private func requirePacket(_ fd: Int32) async throws -> [UInt8] {
        let packet = try await receive(fd)
        return try XCTUnwrap(packet)
    }

    private func validate(_ bytes: [UInt8], type: UInt32, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bytes.count, count, file: file, line: line)
        guard bytes.count >= 20 else { return }
        XCTAssertEqual(Array(bytes.prefix(4)), Array("DSUS".utf8), file: file, line: line)
        XCTAssertEqual(DSUMotionWire.read(bytes, at: 4, as: UInt16.self), 1001, file: file, line: line)
        XCTAssertEqual(Int(DSUMotionWire.read(bytes, at: 6, as: UInt16.self)), count - 16, file: file, line: line)
        XCTAssertEqual(DSUMotionWire.read(bytes, at: 16, as: UInt32.self), type, file: file, line: line)
        var zeroed = bytes
        zeroed.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        XCTAssertEqual(DSUMotionWire.read(bytes, at: 8, as: UInt32.self), DSUMotionWire.crc32(zeroed), file: file, line: line)
    }

    func testStandardCRCAndLengthValidation() {
        XCTAssertEqual(DSUMotionWire.crc32(Array("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(DSUMotionWire.crc32([]), 0)
        let valid = request(0x100000)
        XCTAssertEqual(DSUMotionWire.request(valid)?.type, 0x100000)
        XCTAssertNotNil(DSUMotionWire.request(valid + [9, 8, 7]))
        XCTAssertNil(DSUMotionWire.request(Array(valid.dropLast())))
        XCTAssertNil(DSUMotionWire.request(request(0x100000, version: 1000)))
        var corrupt = valid
        corrupt[12] ^= 1
        XCTAssertNil(DSUMotionWire.request(corrupt))
        corrupt = valid
        corrupt[0] = 0
        XCTAssertNil(DSUMotionWire.request(corrupt))
    }

    @MainActor func testRealUDPVersionListAndExclusivePort() async throws {
        let server = DSUMotionServer(onError: { XCTFail($0) })
        try server.start(port: 0)
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)
        let second = DSUMotionServer(onError: { XCTFail($0) })
        XCTAssertThrowsError(try second.start(port: port))
        let fd = try client(port: port)
        defer { close(fd) }
        send(request(0x100000), to: fd)
        let version = try await requirePacket(fd)
        validate(version, type: 0x100000, count: 22)
        XCTAssertEqual(Array(version.suffix(2)), [0xE9, 3])
        server.setConnected(true)
        send(request(0x100001, DSUMotionWire.integer(UInt32(2)) + [0, 1]), to: fd)
        let first = try await requirePacket(fd)
        let empty = try await requirePacket(fd)
        validate(first, type: 0x100001, count: 32)
        validate(empty, type: 0x100001, count: 32)
        XCTAssertEqual(Array(first[20..<32]), [0, 2, 2, 2, 2, 0, 0, 0, 0, 1, 0, 0])
        XCTAssertEqual(Array(empty[20..<32]), [1] + [UInt8](repeating: 0, count: 11))
        XCTAssertEqual(Array(version[12..<16]), Array(first[12..<16]))
        server.setConnected(false)
        send(request(0x100001, DSUMotionWire.integer(UInt32(1)) + [0]), to: fd)
        let disconnected = try await requirePacket(fd)
        XCTAssertEqual(Array(disconnected[20..<32]), [UInt8](repeating: 0, count: 12))
    }

    @MainActor func testRegistrationsNeverInventSamplesAndDisconnectClearsLease() async throws {
        let server = DSUMotionServer(onError: { XCTFail($0) })
        try server.start(port: 0)
        defer { server.stop() }
        let fd = try client(port: XCTUnwrap(server.boundPort))
        defer { close(fd) }
        let registrations: [[UInt8]] = [
            [UInt8](repeating: 0, count: 8),
            [1, 0, 0, 0, 0, 0, 0, 0],
            [2, 0] + DSUMotionWire.virtualMAC
        ]
        for registration in registrations {
            server.setConnected(true)
            send(request(0x100002, registration), to: fd)
            let premature = try await receive(fd, timeout: .milliseconds(40))
            XCTAssertNil(premature)
            server.setConnected(false)
            let inactive = try await requirePacket(fd)
            validate(inactive, type: 0x100002, count: 100)
            XCTAssertEqual(inactive[21], 0)
            XCTAssertEqual(inactive[31], 0)
            XCTAssertEqual(Array(inactive[68..<100]), [UInt8](repeating: 0, count: 32))
            server.setConnected(true)
            server.setConnected(false)
            let stale = try await receive(fd, timeout: .milliseconds(30))
            XCTAssertNil(stale)
        }
        // 未连接时的注册不会在重连后保留，也不会产生任何运动数据。
        // A disconnected registration does not survive reconnection or produce motion data.
        send(request(0x100002, registrations[0]), to: fd)
        try await Task.sleep(for: .milliseconds(30))
        server.setConnected(true)
        server.setConnected(false)
        let ignored = try await receive(fd, timeout: .milliseconds(30))
        XCTAssertNil(ignored)
    }

    @MainActor func testRejectsMalformedRequestsAndWrongController() async throws {
        let server = DSUMotionServer(onError: { XCTFail($0) })
        try server.start(port: 0)
        defer { server.stop() }
        server.setConnected(true)
        let fd = try client(port: XCTUnwrap(server.boundPort))
        defer { close(fd) }
        var badCRC = request(0x100000)
        badCRC[8] ^= 1
        let invalid = [badCRC, request(0x100000, version: 1002), request(0x100003),
                       request(0x100000, [1]), request(0x100001, [255, 255, 255, 255]),
                       request(0x100001, [1, 0, 0, 0, 4]),
                       request(0x100002, [1, 1, 0, 0, 0, 0, 0, 0]),
                       request(0x100002, [2, 0, 2, 0, 0, 0, 0, 2]),
                       request(0x100002, [4, 0, 0, 0, 0, 0, 0, 0])]
        for packet in invalid { send(packet, to: fd) }
        let response = try await receive(fd, timeout: .milliseconds(50))
        XCTAssertNil(response)
        server.setConnected(false)
        let unexpectedLease = try await receive(fd, timeout: .milliseconds(30))
        XCTAssertNil(unexpectedLease)
    }

    @MainActor func testLeaseExpiresAndStopReleasesPortAndSubscriptions() async throws {
        let server = DSUMotionServer(onError: { XCTFail($0) })
        try server.start(port: 0)
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)
        let fd = try client(port: port)
        defer { close(fd) }
        server.setConnected(true)
        send(request(0x100002, [UInt8](repeating: 0, count: 8)), to: fd)
        try await Task.sleep(for: .milliseconds(5150))
        server.setConnected(false)
        let expired = try await receive(fd, timeout: .milliseconds(30))
        XCTAssertNil(expired)
        server.setConnected(true)
        send(request(0x100002, [UInt8](repeating: 0, count: 8)), to: fd)
        try await Task.sleep(for: .milliseconds(30))
        server.stop()
        let inactive = try await requirePacket(fd)
        validate(inactive, type: 0x100002, count: 100)
        XCTAssertNil(server.boundPort)
        try await Task.sleep(for: .milliseconds(30))
        try server.start(port: port)
        server.setConnected(true)
        server.setConnected(false)
        let stale = try await receive(fd, timeout: .milliseconds(30))
        XCTAssertNil(stale)
    }
}
