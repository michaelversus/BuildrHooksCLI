import Darwin
import Foundation

/// Private, bounded command transport. The watch loop alone dispatches requests into its runtime.
public final class UsageCoordination: @unchecked Sendable {
    public static let maximumFrame = 4096
    public let lockURL: URL
    public let socketURL: URL
    private var ownership: Int32 = -1
    private var listener: Int32 = -1
    private var clients: [Client] = []
    private var endpointInode: ino_t?

    private struct Client {
        let descriptor: Int32
        let deadline: TimeInterval
        var data = Data()
    }

    public init(cacheURL: URL = UsageFileStateStore().fileURL, lockName: String = "account-usage.lock") {
        lockURL = cacheURL.deletingLastPathComponent().appendingPathComponent(lockName)
        socketURL = cacheURL.deletingLastPathComponent().appendingPathComponent("account-usage.sock")
    }

    deinit { close() }

    /// A lock file is never removed: unlinking it would permit two independently locked inodes.
    public func acquire() throws -> Bool {
        guard ownership < 0 else { return true }
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, chmod(directory.path, 0o700) == 0 else {
            throw UsageCoordinationError.unavailable
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsageCoordinationError.unavailable }
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw UsageCoordinationError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            Darwin.close(descriptor)
            if busy {
                return false
            }
            throw UsageCoordinationError.unavailable
        }
        ownership = descriptor
        return true
    }

    public func startServing() throws {
        guard ownership >= 0, listener < 0 else { throw UsageCoordinationError.unavailable }
        var info = stat()
        if lstat(socketURL.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
                  unlink(socketURL.path) == 0 else { throw UsageCoordinationError.unavailable }
        } else if errno != ENOENT {
            throw UsageCoordinationError.unavailable
        }
        let descriptor = try Self.makeSocket()
        do {
            let result = try Self.withAddress(socketURL.path) { bind(descriptor, $0, $1) }
            guard result == 0, chmod(socketURL.path, 0o600) == 0,
                  listen(descriptor, 16) == 0, lstat(socketURL.path, &info) == 0 else {
                throw UsageCoordinationError.unavailable
            }
            endpointInode = info.st_ino
            listener = descriptor
        } catch {
            Darwin.close(descriptor)
            // We hold exclusive ownership; only remove the socket we just bound.
            if lstat(socketURL.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK {
                unlink(socketURL.path)
            }
            throw error
        }
    }

    /// Called synchronously by the owner, never on an independent runtime queue.
    /// Adjacent requests of the same operation share a result; clear separates refresh batches.
    public func serve(dispatch: (UsagePrivateRequest) -> UsageRefreshResult) {
        guard listener >= 0 else { return }
        acceptClients()
        let (waiting, ready) = classifyClients()
        clients = waiting
        guard !ready.isEmpty else { return }
        var previous: UsagePrivateRequest?
        var result: UsageRefreshResult?
        for (descriptor, request) in ready {
            if previous?.operation != request.operation || previous?.provider != request.provider
                || request.operation == .capture {
                result = dispatch(request)
                previous = request
            }
            if let result, let data = try? JSONEncoder().encode(result) {
                _ = Self.sendFrame(descriptor, data: data, deadline: Self.time + 0.2, cancelled: { false })
            }
            Darwin.close(descriptor)
        }
    }

    private func acceptClients() {
        for _ in 0 ..< (16 - clients.count) {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { break }
            guard Self.authorized(descriptor), Self.configure(descriptor) else {
                Darwin.close(descriptor)
                continue
            }
            clients.append(Client(descriptor: descriptor, deadline: Self.time + 2))
        }
    }

    private func classifyClients() -> (waiting: [Client], ready: [(Int32, UsagePrivateRequest)]) {
        var waiting: [Client] = []
        var ready: [(Int32, UsagePrivateRequest)] = []
        for var client in clients {
            let frame = Self.readFrame(client.descriptor, data: &client.data)
            if let request = readyRequest(client, frame: frame) {
                ready.append((client.descriptor, request))
            } else if frame == .waiting, Self.time < client.deadline {
                waiting.append(client)
            } else {
                Darwin.close(client.descriptor)
            }
        }
        return (waiting, ready)
    }

    private func readyRequest(_ client: Client, frame: UsageCoordination.FrameState) -> UsagePrivateRequest? {
        guard frame == .complete,
              let request = try? JSONDecoder().decode(UsagePrivateRequest.self, from: client.data),
              request.version == 1 else { return nil }
        var byte: UInt8 = 0
        return recv(client.descriptor, &byte, 1, MSG_PEEK) != 0 ? request : nil
    }

    /// Delegation retries ownership only while the endpoint is starting or disappearing.
    /// A live lock is never displaced, even when its socket cannot be reached.
    public func refresh(
        runtime: UsageRuntime, timeout: TimeInterval = 40,
        cancelled: @escaping @Sendable () -> Bool = { false },
        request: UsagePrivateRequest = UsagePrivateRequest()
    ) -> UsageRefreshResult {
        let deadline = Self.time + max(0, min(timeout, 40))
        while Self.time < deadline, !cancelled() {
            do {
                if try acquire() {
                    defer { runtime.fetcher.close(); close() }
                    var ownedRuntime = runtime
                    ownedRuntime.isCancelled = { runtime.isCancelled() || cancelled() || Self.time >= deadline }
                    let result = ownedRuntime.dispatch(request)
                    if result.outcome == .cancelled, !cancelled(), !runtime.isCancelled(), Self.time >= deadline {
                        return runtime.result(request.provider, .timeout)
                    }
                    return result
                }
                if let result = try delegate(deadline: deadline, cancelled: cancelled, request: request) {
                    return result
                }
            } catch {
                return runtime.result(request.provider, .coordinationUnavailable)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return runtime.result(request.provider, cancelled() ? .cancelled : .timeout)
    }

    /// Probe the private owner without collecting or mutating retained state.
    public func available(timeout: TimeInterval = 0.3) -> Bool {
        (try? delegate(deadline: Self.time + timeout, cancelled: { false },
                       request: UsagePrivateRequest(operation: .ping)))?.outcome == .collectorRunning
    }

    public func clear(
        runtime: UsageRuntime, provider: UsageProvider = .codex, timeout: TimeInterval = 40,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) -> UsageRefreshResult {
        refresh(runtime: runtime, timeout: timeout, cancelled: cancelled,
                request: UsagePrivateRequest(operation: .clear, provider: provider))
    }

    public func close() {
        clients.forEach { Darwin.close($0.descriptor) }
        clients = []
        if listener >= 0 {
            Darwin.close(listener); listener = -1
        }
        if let endpointInode {
            var info = stat()
            if lstat(socketURL.path, &info) == 0, info.st_ino == endpointInode, info.st_uid == geteuid() {
                unlink(socketURL.path)
            }
            self.endpointInode = nil
        }
        if ownership >= 0 {
            Darwin.close(ownership); ownership = -1
        }
    }
}

extension UsageCoordination {
    private func delegate(deadline: TimeInterval, cancelled: @escaping @Sendable () -> Bool,
                          request: UsagePrivateRequest) throws
        -> UsageRefreshResult? {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw UsageCoordinationError.unavailable
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { throw UsageCoordinationError.unavailable }
        let descriptor = try Self.makeSocket()
        defer { Darwin.close(descriptor) }
        guard let connected = try connectToOwner(descriptor, deadline: deadline, cancelled: cancelled) else {
            return nil
        }
        guard connected else { return timeoutResult(provider: request.provider, cancelled: cancelled) }
        guard Self.authorized(descriptor) else { throw UsageCoordinationError.unavailable }
        return try exchangeRequest(on: descriptor, deadline: deadline, cancelled: cancelled, request: request)
    }

    private func connectToOwner(_ descriptor: Int32, deadline: TimeInterval,
                                cancelled: @escaping @Sendable () -> Bool) throws -> Bool? {
        let connected = try Self.withAddress(socketURL.path) { connect(descriptor, $0, $1) }
        if connected == 0 {
            return true
        }
        if errno == ENOENT || errno == ECONNREFUSED || errno == EAGAIN {
            return nil
        }
        guard errno == EINPROGRESS || errno == EALREADY else { throw UsageCoordinationError.unavailable }
        while Self.time < deadline, !cancelled() {
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&event, 1, 10)
            if polled > 0 {
                return try connectionStatus(descriptor)
            }
            if polled < 0, errno != EINTR {
                throw UsageCoordinationError.unavailable
            }
        }
        return false
    }

    private func connectionStatus(_ descriptor: Int32) throws -> Bool? {
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
            throw UsageCoordinationError.unavailable
        }
        if error == ECONNREFUSED || error == ENOENT {
            return nil
        }
        guard error == 0 else { throw UsageCoordinationError.unavailable }
        return true
    }

    private func exchangeRequest(on descriptor: Int32, deadline: TimeInterval,
                                 cancelled: @escaping @Sendable () -> Bool,
                                 request: UsagePrivateRequest) throws -> UsageRefreshResult {
        let encoded = try JSONEncoder().encode(request)
        guard Self.sendFrame(descriptor, data: encoded, deadline: deadline, cancelled: cancelled) else {
            return timeoutResult(provider: request.provider, cancelled: cancelled)
        }
        var data = Data()
        while Self.time < deadline, !cancelled() {
            switch Self.readFrame(descriptor, data: &data) {
            case .complete:
                let result = try JSONDecoder().decode(UsageRefreshResult.self, from: data)
                guard result.provider == request.provider,
                      result.outcome != .refreshed || (result.freshSnapshot && result.publicationAttempted),
                      result.outcome != .cleared || (result.localCleared && result.publicationAttempted) else {
                    throw UsageCoordinationError.unavailable
                }
                return result
            case .invalid: throw UsageCoordinationError.unavailable
            case .waiting: Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return timeoutResult(provider: request.provider, cancelled: cancelled)
    }

    private func timeoutResult(provider: UsageProvider, cancelled: () -> Bool) -> UsageRefreshResult {
        UsageRefreshResult(provider: provider, outcome: cancelled() ? .cancelled : .timeout,
                           retryAt: nil, freshSnapshot: false, publicationAttempted: false)
    }
}

extension UsageCoordination {
    static var time: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func authorized(_ descriptor: Int32, owner: uid_t = geteuid()) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &user, &group) == 0 && user == owner
    }

    static func configure(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            && fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UsageCoordinationError.unavailable }
        guard configure(descriptor) else { Darwin.close(descriptor); throw UsageCoordinationError.unavailable }
        return descriptor
    }

    static func withAddress<T>(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UsageCoordinationError.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let length = socklen_t(address.sun_len)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    enum FrameState { case waiting, complete, invalid }
    static func readFrame(_ descriptor: Int32, data: inout Data) -> FrameState {
        var buffer = [UInt8](repeating: 0, count: maximumFrame + 1)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 {
            return .invalid
        }
        if count < 0 {
            return errno == EAGAIN || errno == EWOULDBLOCK ? .waiting : .invalid
        }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= maximumFrame else { return .invalid }
        guard let newline = data.firstIndex(of: 10) else { return .waiting }
        guard newline == data.index(before: data.endIndex) else { return .invalid }
        data.removeLast()
        return .complete
    }

    static func sendFrame(_ descriptor: Int32, data: Data, deadline: TimeInterval,
                          cancelled: () -> Bool) -> Bool {
        guard data.count < maximumFrame else { return false }
        let frame = data + Data([10])
        var offset = 0
        while offset < frame.count, time < deadline, !cancelled() {
            let count = frame.withUnsafeBytes { bytes in
                send(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.001)
            } else {
                return false
            }
        }
        return offset == frame.count
    }
}
