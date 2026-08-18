// Unix-domain sentinel for a single Cyder primary and per-launch Wine trees.
//
// The primary binds `sentinel.sock`. Each launch helper connects, holds the
// socket until its wait fifo hits EOF (and the watched Wine PID exits), then
// the kernel closes the fd. The primary treats disconnect as "this launch ended".
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
        if bindListen() {
            startAccept()
            return .primary
        }
        if CyderSentinelConnect.canConnect(to: socketURL) {
            return .secondary
        }
        unlinkSocket()
        if bindListen() {
            startAccept()
            return .primary
        }
        if CyderSentinelConnect.canConnect(to: socketURL) {
            return .secondary
        }
        return .unavailable
    }

    func stop() {
        queue.sync {
            for fd in clients.keys { closeClient(fd) }
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            if ownsSocket {
                unlinkSocket()
                ownsSocket = false
            }
        }
    }

    deinit { stop() }

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
        source.setCancelHandler {
            // The listen fd is closed in stop().
        }
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
        source.setCancelHandler {
            close(fd)
        }
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
            fifoFD = open(fifo, O_RDONLY)
        }
        defer { if fifoFD >= 0 { close(fifoFD) } }

        let fd = connectSocket()
        guard fd >= 0 else { return 1 }
        defer { close(fd) }

        send(fd: fd, [
            "v": 1,
            "kind": "hello",
            "id": id,
            "prefix": prefix,
            "exe": exe,
            "pid": watchPID,
            "holders": [],
        ])

        var fifoEOF = fifoFD < 0
        var idleWithoutHolders = 0
        while true {
            if watchPID <= 0, !pidFile.isEmpty {
                if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                   let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   value > 0 {
                    watchPID = value
                }
            }
            if !fifoEOF, fifoFD >= 0 {
                fifoEOF = fifoHasEOF(fifoFD)
            }
            let holders = currentHolders(prefix: prefix, watchPID: watchPID)
            send(fd: fd, [
                "v": 1,
                "kind": "update",
                "id": id,
                "prefix": prefix,
                "exe": exe,
                "pid": watchPID,
                "holders": holders.map {
                    ["pid": $0.pid, "name": $0.name, "window": $0.hasWindow]
                },
            ])
            let pidAlive = watchPID > 0 && kill(watchPID, 0) == 0
            if !pidAlive && fifoEOF {
                if holders.isEmpty {
                    idleWithoutHolders += 1
                    if idleWithoutHolders >= 3 { break }
                } else {
                    idleWithoutHolders = 0
                }
            } else {
                idleWithoutHolders = 0
            }
            usleep(400_000)
        }
        return 0
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

    private static func fifoHasEOF(_ fd: Int32) -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&pollFD, 1, 0)
        guard ready > 0 else { return false }
        if pollFD.revents & Int16(POLLHUP) != 0 {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            return n <= 0
        }
        if pollFD.revents & Int16(POLLIN) != 0 {
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            return n == 0
        }
        return false
    }

    private static func currentHolders(prefix: String, watchPID: Int32) -> [CyderSentinelHolder] {
        var pids = Set<Int32>()
        if watchPID > 0, kill(watchPID, 0) == 0 {
            pids.formUnion(wineProcessTreeIDs(root: watchPID))
        }
        let windows = wineOnscreenWindows(matchingPrefix: prefix, extraPIDs: pids)
        for window in windows where window.pid > 0 {
            pids.insert(window.pid)
        }
        if watchPID <= 0 || kill(watchPID, 0) != 0 {
            for window in wineOnscreenWindows(matchingPrefix: prefix) {
                pids.insert(window.pid)
            }
        }
        let windowByPID = Dictionary(uniqueKeysWithValues: windows.map { ($0.pid, $0) })
        return pids.sorted().compactMap { pid in
            guard pid > 0, kill(pid, 0) == 0 else { return nil }
            if !isWineLoaderPID(pid), windowByPID[pid] == nil { return nil }
            let windowName = windowByPID[pid].flatMap { cyderUsefulWindowOwnerName($0.ownerName) }
            let name = windowName ?? cyderWineArgvName(pid: pid) ?? ""
            return CyderSentinelHolder(pid: pid, name: name, hasWindow: windowByPID[pid] != nil)
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
