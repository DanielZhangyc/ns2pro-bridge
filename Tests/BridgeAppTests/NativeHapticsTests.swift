import XCTest
import Darwin
@testable import BridgeApp

final class NativeHapticsTests: XCTestCase {
    private func frame(duration: Int = 200, amplitude: Float = 0.15, frequency: Float = 160, version: Int = 1) -> HapticFrame {
        let band = HapticBand(lowAmplitude: amplitude, lowFrequency: frequency, highAmplitude: 0.1, highFrequency: 320)
        return HapticFrame(version: version, durationMilliseconds: duration, left: band, right: band)
    }

    func testValidation() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(try HapticFrame.decode(encoder.encode(frame())).durationMilliseconds, 200)
        for value in [frame(duration: -1), frame(duration: 1001), frame(amplitude: -0.1),
                      frame(amplitude: 1.1), frame(frequency: 39), frame(frequency: 1253), frame(version: 2)] {
            XCTAssertThrowsError(try HapticFrame.decode(encoder.encode(value)))
        }
        XCTAssertNoThrow(try HapticFrame.decode(encoder.encode(frame(duration: 0))))
        XCTAssertThrowsError(try HapticFrame.decode(Data(repeating: 32, count: 2049)))
        XCTAssertThrowsError(try HapticFrame.decode(Data("{}".utf8)))
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/ns2pro-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func address(_ path: String) -> sockaddr_un {
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        precondition(bytes.count <= MemoryLayout.size(ofValue: result.sun_path))
        withUnsafeMutableBytes(of: &result.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        return result
    }

    private func connect(_ descriptor: Int32, path: String) -> Int32 {
        var addr = address(path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    @MainActor func testRealDatagramAndExclusiveLock() async throws {
        let directory = try directory()
        defer { try! FileManager.default.removeItem(at: directory) }
        var received: HapticFrame?
        var errors: [String] = []
        let server = NativeHapticsServer(directory: directory, onFrame: { received = $0 }, onError: { errors.append($0) })
        try server.start()
        defer { server.stop() }
        let second = NativeHapticsServer(directory: directory, onFrame: { _ in XCTFail("Second server received data") }, onError: { _ in })
        XCTAssertThrowsError(try second.start())
        let path = directory.appendingPathComponent("haptics.sock").path
        let client = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        XCTAssertEqual(connect(client, path: path), 0)
        let encoded = try JSONEncoder().encode(frame())
        XCTAssertEqual(encoded.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }, encoded.count)
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(received?.left.lowFrequency, 160)
        let invalid = Data("{}".utf8)
        XCTAssertEqual(invalid.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }, invalid.count)
        for _ in 0..<100 where errors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(errors.count, 1)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try second.start()
        second.stop()
    }

    @MainActor func testRecoversActualOrphanedSocket() throws {
        let directory = try directory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("haptics.sock").path
        let old = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(old, 0)
        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(old, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(chmod(path, 0o600), 0)
        close(old)
        let server = NativeHapticsServer(directory: directory, onFrame: { _ in }, onError: { XCTFail($0) })
        try server.start()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor func testRejectsSymlinkWithoutRemovingTarget() throws {
        let directory = try directory()
        defer { try! FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let path = directory.appendingPathComponent("haptics.sock")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        let server = NativeHapticsServer(directory: directory, onFrame: { _ in }, onError: { _ in })
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testGuideAndShareMapping() {
        let report = XboxReports.input(buttons: (1 << 16) | (1 << 17), lx: 0, ly: 0, rx: 0, ry: 0)
        XCTAssertEqual(report[15], 0x10)
        XCTAssertEqual(report[16], 1)
    }
}
