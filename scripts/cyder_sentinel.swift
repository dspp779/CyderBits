// Unix-domain sentinel for a single Cyder primary and per-launch Wine trees.
//
// The primary binds `sentinel.sock`. Each launch helper connects and holds the
// socket until its wait fifo hits EOF. Disconnect means the helper is gone;
// Wine may still be running, so the UI keeps the launch until process-exit
// events (and helper disconnect) both say it is finished.
import Darwin
import Foundation

struct CyderSentinelHolder {
    let pid: Int32
    let name: String
    let hasWindow: Bool
}

struct CyderSentinelLaunch {
    let id: String
    let prefix: String
    let rootName: String
    var pid: Int32
    var holders: [CyderSentinelHolder]
}

final class CyderSentinelServer {
    enum Role {
        case primary
        case secondary
        case unavailable
    }

    var onLaunch: ((CyderSentinelLaunch) -> Void)?
    var onLaunchUpdate: ((CyderSentinelLaunch) -> Void)?
    var onLaunchEnded: ((String) -> Void)?

    private let socketURL: URL
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "local.cyder.sentinel")
    private var clients: [Int32: Client] = [:]
    private var ownsSocket = false
    private var ownerFD: Int32 = -1
    private let resources = DispatchGroup()

    init(
        support: URL = CyderPaths.support,
        bundleID: String = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
            ?? Bundle.main.bundleIdentifier
            ?? "local.cyder.app"
    ) {
        let identity = bundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        socketURL = support.appendingPathComponent(".native-sentinel-\(identity).sock")
    }

    func becomePrimary() -> Role {
        let parent = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: parent.path
            )
        } catch {
            return .unavailable
        }
        // A hung primary keeps its kernel lock. Socket responsiveness cannot
        // authorize a replacement executor or removal of a live endpoint.
        let lockPath = socketURL.path + ".owner"
        let lock = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return .unavailable }
        var identity = stat()
        guard fstat(lock, &identity) == 0, identity.st_uid == getuid(),
              (identity.st_mode & S_IFMT) == S_IFREG else { close(lock); return .unavailable }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(lock)
            return busy ? .secondary : .unavailable
        }
        ownerFD = lock
        if bindListen() {
            startAccept()
            return .primary
        }
        // Migration: an older primary may hold only the socket. Only a definite
        // ECONNREFUSED on its endpoint permits reclaiming it; timeout is unknown.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        var status: Int32 = EINVAL
        if probe >= 0, var address = unixSocketAddress(socketURL.path) {
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            status = result == 0 ? 0 : errno
        }
        if probe >= 0 { close(probe) }
        if status == ECONNREFUSED {
            unlinkSocket()
            if bindListen() { startAccept(); return .primary }
        }
        close(ownerFD)
        ownerFD = -1
        return status == 0 || status == EINPROGRESS || status == EAGAIN ? .secondary : .unavailable
    }

    func stop(completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            for fd in Array(clients.keys) { closeClient(fd) }
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            resources.notify(queue: queue) { [self] in
                if ownsSocket { unlinkSocket(); ownsSocket = false }
                if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }
                completion()
            }
        }
    }

    deinit {
        acceptSource?.cancel()
        for client in clients.values { client.source.cancel() }
        if ownerFD >= 0 { close(ownerFD) }
    }

    private func bindListen() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = unixSocketAddress(socketURL.path) else {
            close(fd)
            return false
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }
        _ = chmod(socketURL.path, 0o600)
        listenFD = fd
        ownsSocket = true
        return true
    }

    private func startAccept() {
        let fd = listenFD
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        resources.enter()
        source.setCancelHandler { [resources] in close(fd); resources.leave() }
        acceptSource = source
        source.resume()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard clients.count < 128, getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let flags = fcntl(client, F_GETFL)
            if flags >= 0 {
                _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
            }
            serve(client)
        }
    }

    private func serve(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let client = Client(fd: fd, source: source)
        clients[fd] = client
        source.setEventHandler { [weak self] in
            self?.readClient(fd)
        }
        resources.enter()
        source.setCancelHandler { [resources] in close(fd); resources.leave() }
        source.resume()
    }

    private func readClient(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &buffer, buffer.count, 0)
        if received < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            finish(client)
            return
        }
        if received == 0 {
            finish(client)
            return
        }
        guard client.pending.count + received <= 262144 else { finish(client); return }
        client.pending.append(contentsOf: buffer.prefix(received))
        while let line = client.nextLine() {
            apply(line, to: &client)
        }
        clients[fd] = client
        if let launch = client.launch {
            let snapshot = launch
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if client.announced {
                    self.onLaunchUpdate?(snapshot)
                } else {
                    self.onLaunch?(snapshot)
                }
            }
            client.announced = true
            clients[fd] = client
        }
    }

    private func apply(_ line: String, to client: inout Client) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let kind = object["kind"] as? String ?? ""
        let id = object["id"] as? String ?? client.launch?.id ?? UUID().uuidString
        let prefix = object["prefix"] as? String ?? client.launch?.prefix ?? ""
        let exe = object["exe"] as? String ?? client.launch?.rootName ?? "Wine"
        let pid = int32(object["pid"]) ?? client.launch?.pid ?? 0
        let holders = (object["holders"] as? [[String: Any]] ?? []).compactMap { raw -> CyderSentinelHolder? in
            guard let holderPID = int32(raw["pid"]) else { return nil }
            return CyderSentinelHolder(
                pid: holderPID,
                name: raw["name"] as? String ?? "",
                hasWindow: raw["window"] as? Bool ?? false
            )
        }
        if kind == "hello" || client.launch == nil {
            client.launch = CyderSentinelLaunch(
                id: id,
                prefix: prefix,
                rootName: exe,
                pid: pid,
                holders: holders
            )
        } else if var launch = client.launch {
            launch.pid = pid
            if !holders.isEmpty || kind == "update" {
                launch.holders = holders
            }
            client.launch = launch
        }
    }

    private func finish(_ client: Client) {
        closeClient(client.fd)
        if let id = client.launch?.id {
            DispatchQueue.main.async { [weak self] in
                self?.onLaunchEnded?(id)
            }
        }
    }

    private func closeClient(_ fd: Int32) {
        if let client = clients.removeValue(forKey: fd) {
            client.source.cancel()
        }
    }

    private func unlinkSocket() {
        unlink(socketURL.path)
    }

    private func int32(_ value: Any?) -> Int32? {
        if let number = value as? Int { return Int32(number) }
        if let number = value as? Int32 { return number }
        if let number = value as? NSNumber { return number.int32Value }
        if let text = value as? String { return Int32(text) }
        return nil
    }

    private struct Client {
        let fd: Int32
        let source: DispatchSourceRead
        var pending = Data()
        var launch: CyderSentinelLaunch?
        var announced = false

        mutating func nextLine() -> String? {
            guard let newline = pending.firstIndex(of: 0x0a) else { return nil }
            let slice = pending[..<newline]
            pending.removeSubrange(...newline)
            return String(data: slice, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum CyderSentinelConnect {
    static func run(arguments: [String]) -> Int32 {
        closeInheritedHelperFileDescriptors()
        var prefix = ""
        var exe = "Wine"
        var fifo = ""
        var pidFile = ""
        var watchPID: Int32 = 0
        var index = arguments.startIndex
        if index < arguments.endIndex { arguments.formIndex(after: &index) }
        while index < arguments.endIndex {
            let arg = arguments[index]
            arguments.formIndex(after: &index)
            func take() -> String {
                guard index < arguments.endIndex else { return "" }
                let value = arguments[index]
                arguments.formIndex(after: &index)
                return value
            }
            switch arg {
            case "--sentinel-connect":
                continue
            case "--prefix":
                prefix = take()
            case "--exe":
                exe = take()
            case "--fifo":
                fifo = take()
            case "--pid-file":
                pidFile = take()
            case "--watch-pid":
                watchPID = Int32(take()) ?? 0
            default:
                continue
            }
        }
        let id = UUID().uuidString
        var fifoFD: Int32 = -1
        if !fifo.isEmpty {
            // The supervisor may publish the PID and close its writer before
            // dyld starts this helper. A blocking read-open then waits forever
            // for a writer that will never return.
            fifoFD = open(fifo, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fifoFD >= 0 {
                var info = stat()
                if fstat(fifoFD, &info) != 0 || info.st_mode & S_IFMT != S_IFIFO || info.st_uid != getuid() {
                    close(fifoFD); fifoFD = -1
                }
            }
        }
        let socketFD = connectSocket()
        guard socketFD >= 0 else {
            if fifoFD >= 0 { close(fifoFD) }
            return 1
        }

        send(fd: socketFD, [
            "v": 1,
            "kind": "hello",
            "id": id,
            "prefix": prefix,
            "exe": exe,
            "pid": watchPID,
            "holders": [],
        ])

        let queue = DispatchQueue(label: "local.cyder.sentinel-connect")
        let finished = DispatchSemaphore(value: 0)
        var pidSource: DispatchSourceFileSystemObject?
        var fifoSource: DispatchSourceRead?

        var processSource: DispatchSourceProcess?
        var fifoClosed = false
        let socketSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        socketSource.setEventHandler {
            var byte: UInt8 = 0
            let count = recv(socketFD, &byte, 1, MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                finished.signal() // primary disappeared; never signal Wine
            }
        }
        socketSource.setCancelHandler { close(socketFD) }
        socketSource.resume()

        func publishPID(_ pid: Int32) {
            guard pid > 0 else { return }
            watchPID = pid
            send(fd: socketFD, [
                "v": 1,
                "kind": "update",
                "id": id,
                "prefix": prefix,
                "exe": exe,
                "pid": pid,
                "holders": [],
            ])
            watchProcess(pid)
        }

        func watchProcess(_ pid: Int32) {
            guard pid > 0, processSource == nil else { return }
            if kill(pid, 0) != 0 {
                if fifoClosed { finished.signal() }
                return
            }
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: queue
            )
            source.setEventHandler {
                source.cancel()
                if fifoClosed { finished.signal() }
            }
            processSource = source
            source.resume()
        }

        func finishIfIdle() {
            let pid = watchPID > 0 ? watchPID : readPIDFile()
            if pid > 0, kill(pid, 0) == 0 {
                publishPID(pid)
                return
            }
            finished.signal()
        }

        func readPIDFile() -> Int32 {
            guard !pidFile.isEmpty,
                  let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0 else { return 0 }
            return pid
        }

        queue.sync {
            if watchPID <= 0 {
                watchPID = readPIDFile()
            }
            if watchPID > 0 {
                publishPID(watchPID)
            } else if !pidFile.isEmpty {
                let directory = (pidFile as NSString).deletingLastPathComponent
                let directoryFD = open(directory, O_EVTONLY)
                if directoryFD >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: directoryFD,
                        eventMask: [.write, .extend, .attrib, .link, .rename],
                        queue: queue
                    )
                    source.setEventHandler {
                        let pid = readPIDFile()
                        guard pid > 0 else { return }
                        publishPID(pid)
                        source.cancel()
                    }
                    source.setCancelHandler { close(directoryFD) }
                    pidSource = source
                    source.resume()
                }
            }

            if fifoFD >= 0 {
                let flags = fcntl(fifoFD, F_GETFL)
                if flags >= 0 {
                    _ = fcntl(fifoFD, F_SETFL, flags | O_NONBLOCK)
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fifoFD, queue: queue)
                func readFIFO() {
                    guard !fifoClosed else { return }
                    var buffer = [UInt8](repeating: 0, count: 64)
                    while true {
                        let count = read(fifoFD, &buffer, buffer.count)
                        if count == 0 {
                            fifoClosed = true
                            source.cancel()
                            finishIfIdle()
                            return
                        }
                        if count < 0 {
                            if errno == EAGAIN || errno == EWOULDBLOCK { return }
                            fifoClosed = true
                            source.cancel()
                            finishIfIdle()
                            return
                        }
                    }
                }
                source.setEventHandler(handler: readFIFO)
                source.setCancelHandler { close(fifoFD) }
                fifoSource = source
                source.resume()
                // EOF already present when the source was registered may not
                // generate a new edge. Inspect once on the same serialized queue.
                queue.async(execute: readFIFO)
            } else {
                finished.signal()
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if watchPID <= 0 { finished.signal() } // missing publication is not Wine exit proof
            }
        }

        finished.wait()
        queue.sync {
            pidSource?.cancel()
            fifoSource?.cancel()
            processSource?.cancel()
            socketSource.cancel()
        }
        return 0
    }

    /// Drop fds inherited from the supervisor (`exec 3<>fifo`). An RDWR fifo
    /// kept by this helper is a writer, so the read watch never sees EOF.
    private static func closeInheritedHelperFileDescriptors() {
        let rawLimit = getdtablesize()
        let limit: Int32 = rawLimit > 3 ? min(rawLimit, 256) : 3
        var fd: Int32 = 3
        while fd < limit {
            _ = Darwin.close(fd)
            fd += 1
        }
    }

    static func canConnect(to url: URL) -> Bool {
        let fd = connectSocket(path: url.path)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    private static func connectSocket(path: String? = nil) -> Int32 {
        let socketURL: URL = {
            if let path { return URL(fileURLWithPath: path) }
            let bundleID = ProcessInfo.processInfo.environment["CYDER_BUNDLE_ID"]
                ?? Bundle.main.bundleIdentifier
                ?? "local.cyder.app"
            let identity = bundleID.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "_",
                options: .regularExpression
            )
            return CyderPaths.support.appendingPathComponent(".native-sentinel-\(identity).sock")
        }()
        for _ in 0..<40 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            guard var addr = unixSocketAddress(socketURL.path) else {
                close(fd)
                return -1
            }
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return fd }
            close(fd)
            usleep(50_000)
        }
        return -1
    }

    private static func send(fd: Int32, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        line.withCString { pointer in
            _ = Darwin.send(fd, pointer, strlen(pointer), 0)
        }
    }

}

private func unixSocketAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count + 1 <= capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + bytes.count + 1)
    return addr
}
