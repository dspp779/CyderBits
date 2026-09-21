import Foundation
import Darwin

struct CyderRequestMessage: Codable {
    let protocolVersion: Int
    let kind: String
    let requestID: String?
    let payloadDigest: String?
    let senderEpoch: UUID
    let payload: CyderRequestPayload?
}
struct CyderRequestReply: Codable {
    let protocolVersion: Int
    let requestID: String?
    let primaryEpoch: UUID
    let namespace: UUID?
    let status: String
    let record: CyderRequestJournal.Record?
}

/// Bounded, same-user Unix stream channel. Exactly one JSON line per connection.
/// Transport completion never substitutes for journal acceptance.
final class CyderRequestChannel {
    private let path: String
    private let queue = DispatchQueue(label: "local.cyder.request-channel")
    private var listener: DispatchSourceRead?
    private var fd: Int32 = -1
    private var boundIdentity: (dev_t, ino_t)?
    private let resources = DispatchGroup()
    private struct Client {
        let token: UUID
        let source: DispatchSourceRead
        var bytes = Data()
        var delivered = false
    }
    private var clients: [Int32: Client] = [:]
    private var handler: ((CyderRequestMessage, @escaping (CyderRequestReply) -> Void) -> Void)?
    static let maxFrame = 256 * 1024
    init(path: String) { self.path = path }

    /// Call only while holding the primary ownership and journal locks.
    func start(handler: @escaping (CyderRequestMessage, @escaping (CyderRequestReply) -> Void) -> Void) -> Bool {
        precondition(!Thread.isMainThread)
        self.handler = handler
        guard let address = Self.address(path) else { return false }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        Self.configure(socketFD)
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        unlink(path)
        var addr = address
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(socketFD); return false }
        var identity = stat()
        guard lstat(path, &identity) == 0, identity.st_mode & S_IFMT == S_IFSOCK else { close(socketFD); return false }
        boundIdentity = (identity.st_dev, identity.st_ino)
        guard chmod(path, 0o600) == 0, listen(socketFD, 16) == 0 else {
            close(socketFD)
            return false
        }
        fd = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        resources.enter()
        source.setCancelHandler { [resources] in close(socketFD); resources.leave() }
        listener = source
        source.resume()
        return true
    }

    func stop(completion: @escaping () -> Void) {
        queue.async { [self] in
            for clientFD in Array(clients.keys) { remove(clientFD) }
            listener?.cancel()
            listener = nil
            fd = -1
            if let identity = boundIdentity {
                var current = stat()
                if lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
                   current.st_dev == identity.0, current.st_ino == identity.1 { unlink(path) }
                boundIdentity = nil
            }
            // Sources own their FD until cancellation executes on this queue.
            resources.notify(queue: queue, execute: completion)
        }
    }

    private func acceptClients() {
        guard fd >= 0 else { return }
        for _ in 0..<32 {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            guard clients.count < 16, Self.sameUser(clientFD) else { close(clientFD); continue }
            Self.configure(clientFD)
            _ = fcntl(clientFD, F_SETFL, O_NONBLOCK)
            let token = UUID()
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            clients[clientFD] = Client(token: token, source: source)
            source.setEventHandler { [weak self] in self?.read(clientFD, token: token) }
            resources.enter()
            source.setCancelHandler { [resources] in close(clientFD); resources.leave() }
            source.resume()
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard self?.clients[clientFD]?.token == token else { return }
                self?.remove(clientFD)
            }
        }
    }

    private func read(_ clientFD: Int32, token: UUID) {
        guard var client = clients[clientFD], client.token == token else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(clientFD, &buffer, buffer.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        guard count > 0, !client.delivered else { remove(clientFD); return }
        client.bytes.append(contentsOf: buffer.prefix(count))
        guard client.bytes.count <= Self.maxFrame else { remove(clientFD); return }
        clients[clientFD] = client
        guard let newline = client.bytes.firstIndex(of: 10) else { return }
        guard newline == client.bytes.count - 1,
              let message = try? JSONDecoder().decode(CyderRequestMessage.self, from: client.bytes.prefix(newline)),
              message.protocolVersion == 1 else { remove(clientFD); return }
        clients[clientFD]?.delivered = true
        handler?(message) { [weak self] reply in
            guard let self else { return }
            self.queue.async {
                guard self.clients[clientFD]?.token == token,
                      let encoded = try? JSONEncoder().encode(reply), encoded.count < Self.maxFrame else { return }
                var bytes = encoded
                bytes.append(10)
                // If the peer cannot consume this bounded reply immediately,
                // drop the channel; a same-ID query recovers the durable result.
                bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = send(clientFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        offset += count
                    }
                }
                self.remove(clientFD)
            }
        }
    }

    private func remove(_ clientFD: Int32) { clients.removeValue(forKey: clientFD)?.source.cancel() }

    /// The caller supplies its own bounded worker and retry budget. No AppKit or
    /// LifecycleStore thread may synchronously wait for a peer.
    static func exchange(path: String, message: CyderRequestMessage, timeout: TimeInterval = 1) -> CyderRequestReply? {
        precondition(!Thread.isMainThread)
        guard var addr = address(path), var data = try? JSONEncoder().encode(message), data.count < maxFrame else { return nil }
        data.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        configure(fd)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func budget() -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            let bounded = min(remaining, 1)
            var interval = timeval(tv_sec: Int(bounded), tv_usec: Int32(max(1, bounded.truncatingRemainder(dividingBy: 1) * 1_000_000)))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            return true
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            guard poll(&pollFD, 1, Int32(min(remaining * 1000, Double(Int32.max)))) > 0 else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        guard sameUser(fd), budget() else { return nil }
        _ = fcntl(fd, F_SETFL, 0)
        let sent = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                guard budget() else { return false }
                let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard sent else { return nil }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while received.count <= maxFrame {
            guard budget() else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            received.append(contentsOf: buffer.prefix(count))
            if let newline = received.firstIndex(of: 10) {
                guard newline == received.count - 1, received.count <= maxFrame,
                      let reply = try? JSONDecoder().decode(CyderRequestReply.self, from: received.prefix(newline)),
                      reply.protocolVersion == 1, reply.requestID == message.requestID else { return nil }
                return reply
            }
        }
        return nil
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    private static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(bytes.count + 3)
        return address
    }
}
