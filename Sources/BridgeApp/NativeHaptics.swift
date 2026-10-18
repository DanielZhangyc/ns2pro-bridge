import Foundation
import Darwin

struct HapticBand: Codable, Sendable {
    let lowAmplitude: Float
    let lowFrequency: Float
    let highAmplitude: Float
    let highFrequency: Float

    var isValid: Bool {
        [lowAmplitude, highAmplitude].allSatisfy { $0.isFinite && (0...1).contains($0) }
        && [lowFrequency, highFrequency].allSatisfy { $0.isFinite && (40...1252).contains($0) }
    }
}

struct HapticFrame: Codable, Sendable {
    let version: Int
    let durationMilliseconds: Int
    let left: HapticBand
    let right: HapticBand

    static func decode(_ data: Data) throws -> HapticFrame {
        guard data.count <= 2048 else { throw NativeHapticsError.invalidFrame }
        let frame: Self
        do { frame = try JSONDecoder().decode(Self.self, from: data) }
        catch is DecodingError { throw NativeHapticsError.invalidFrame }
        guard frame.version == 1, (0...1000).contains(frame.durationMilliseconds),
              frame.left.isValid, frame.right.isValid else { throw NativeHapticsError.invalidFrame }
        return frame
    }
}

enum NativeHapticsError: LocalizedError {
    case invalidFrame
    case system(String, Int32)
    case unsafeDirectory
    case unsafeEndpoint
    var errorDescription: String? {
        switch self {
        case .invalidFrame: L10n.text("Invalid dual-frequency frame. Check amplitudes, frequencies, and duration.")
        case let .system(operation, code): L10n.format("%@: %@", operation, String(cString: strerror(code)))
        case .unsafeDirectory: L10n.text("Unsafe dual-frequency interface directory permissions. Use a directory owned by the current user with mode 0700.")
        case .unsafeEndpoint: L10n.text("Unsafe dual-frequency endpoint type, ownership, or permissions. The existing file was not changed.")
        }
    }
}

// 每个数据报是一帧；租约到期必须停止，不需要客户端可靠退出。
// Each datagram is one frame; lease expiry stops motors without requiring a clean client exit.
@MainActor final class NativeHapticsServer {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var boundPath: String?
    private var directoryDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var boundIdentity: (device: dev_t, inode: ino_t)?
    private let directoryURL: URL
    let onFrame: (HapticFrame) -> Void
    let onError: (String) -> Void
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ns2pro-bridge", isDirectory: true)
    }
    static var socketPath: String { directory.appendingPathComponent("haptics.sock").path }

    init(directory: URL = NativeHapticsServer.directory,
         onFrame: @escaping (HapticFrame) -> Void, onError: @escaping (String) -> Void) {
        directoryURL = directory
        self.onFrame = onFrame
        self.onError = onError
    }

    func start() throws {
        guard descriptor == -1 else { return }
        let directory = directoryURL.path
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw NativeHapticsError.system(L10n.text("Could not create the dual-frequency interface directory"), errno)
        }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw NativeHapticsError.system(L10n.text("Could not open the dual-frequency interface directory"), errno) }
        var accepted = false
        defer { if !accepted { close(directoryFD) } }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw NativeHapticsError.unsafeDirectory
        }
        // 生命周期锁先于端点检查与回收，禁止另一个实例删除仍在使用的 socket。
        // Acquire a lifetime lock before checking or recovering the endpoint, preventing another instance from unlinking a live socket.
        let lockFD = openat(directoryFD, "haptics.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw NativeHapticsError.system(L10n.text("Could not open the dual-frequency interface lock"), errno) }
        defer { if !accepted { close(lockFD) } }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1,
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o777 == 0o600 else {
            throw NativeHapticsError.unsafeEndpoint
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw NativeHapticsError.system(L10n.text("Another instance is using the dual-frequency interface"), errno)
        }
        let path = directoryURL.appendingPathComponent("haptics.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NativeHapticsError.system(L10n.text("The dual-frequency interface path is too long"), ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var endpoint = stat()
        if fstatat(directoryFD, "haptics.sock", &endpoint, AT_SYMLINK_NOFOLLOW) == 0 {
            guard endpoint.st_uid == getuid(), endpoint.st_mode & S_IFMT == S_IFSOCK,
                  endpoint.st_mode & 0o777 == 0o600 else { throw NativeHapticsError.unsafeEndpoint }
            let probe = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard probe >= 0 else { throw NativeHapticsError.system(L10n.text("Could not check the dual-frequency endpoint"), errno) }
            guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
                let code = errno
                close(probe)
                throw NativeHapticsError.system(L10n.text("Could not configure the dual-frequency endpoint check"), code)
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let probeError = errno
            close(probe)
            guard result != 0 else { throw NativeHapticsError.system(L10n.text("The existing dual-frequency endpoint is still in use"), EADDRINUSE) }
            guard probeError == ECONNREFUSED else {
                throw NativeHapticsError.system(L10n.text("Could not confirm that the dual-frequency endpoint is inactive"), probeError)
            }
            guard unlinkat(directoryFD, "haptics.sock", 0) == 0 else {
                throw NativeHapticsError.system(L10n.text("Could not remove the inactive dual-frequency endpoint"), errno)
            }
        } else if errno != ENOENT {
            throw NativeHapticsError.system(L10n.text("Could not inspect the dual-frequency endpoint file"), errno)
        }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw NativeHapticsError.system(L10n.text("Could not create the dual-frequency interface"), errno) }
        defer { if !accepted { close(fd) } }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw NativeHapticsError.system(L10n.text("Could not configure the dual-frequency interface"), errno)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw NativeHapticsError.system(L10n.text("Could not bind the dual-frequency interface; check for another instance or a stale socket"), errno) }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            unlink(path)
            throw NativeHapticsError.system(L10n.text("Could not set dual-frequency interface permissions"), code)
        }
        var boundInfo = stat()
        guard fstatat(directoryFD, "haptics.sock", &boundInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            unlinkat(directoryFD, "haptics.sock", 0)
            throw NativeHapticsError.system(L10n.text("Could not read the dual-frequency endpoint status"), code)
        }
        descriptor = fd
        boundPath = path
        directoryDescriptor = directoryFD
        lockDescriptor = lockFD
        boundIdentity = (boundInfo.st_dev, boundInfo.st_ino)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.receive() }
        }
        readSource.setCancelHandler { close(fd) }
        source = readSource
        accepted = true
        readSource.resume()
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 2049)
        // 限制每轮读取，避免客户端淹没主线程。
        // Bound each drain so a client cannot starve the main thread.
        for _ in 0..<32 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                onError(NativeHapticsError.system(L10n.text("Could not read the dual-frequency interface"), errno).localizedDescription)
                stop()
                return
            }
            do { onFrame(try HapticFrame.decode(Data(buffer.prefix(count)))) }
            catch { onError(error.localizedDescription) }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        if boundPath != nil, let boundIdentity {
            var current = stat()
            if fstatat(directoryDescriptor, "haptics.sock", &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_mode & S_IFMT == S_IFSOCK,
               current.st_dev == boundIdentity.device, current.st_ino == boundIdentity.inode {
                if unlinkat(directoryDescriptor, "haptics.sock", 0) != 0 {
                    onError(NativeHapticsError.system(L10n.text("Could not remove the dual-frequency endpoint"), errno).localizedDescription)
                }
            } else if errno != ENOENT {
                onError(L10n.text("The dual-frequency endpoint was replaced or could not be inspected. The path was not deleted."))
            }
        }
        boundPath = nil
        boundIdentity = nil
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
        if directoryDescriptor >= 0 { close(directoryDescriptor); directoryDescriptor = -1 }
    }
}
