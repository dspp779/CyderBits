import Foundation
import Darwin

/// Who is using an engine's shared runtime files.
///
/// The MoltenVK `.real` link and the GPTK link are shared by every bottle of an
/// engine and are read whenever a Wine process loads them, not only when it
/// starts (a game may create its Vulkan device late, or a launcher may start
/// the real game later). Repointing one under a running process would mix two
/// versions inside one game. A switch is therefore allowed only while no Wine
/// client process of that engine runs.
///
/// The caller holds the exclusive all-environments scope: every Cyder
/// preparation holds that scope shared until its Wine process is spawned, so
/// none can start a client between this check and the switch.
enum CyderRuntimeUsers {
    struct User: Equatable {
        let pid: Int32
        /// The bottle, when the process's WINEPREFIX is readable.
        let prefix: String?
        let name: String
    }
    static let marker = "CYDER-RUNTIME-IN-USE"

    /// Process-table reads, injectable for tests.
    struct Probe {
        var pids: () -> [Int32]? = CyderProcessTable.completePIDs
        var image: (Int32) -> String? = CyderProcessTable.image
        var arguments: (Int32) -> CyderProcessTable.Arguments? = CyderProcessTable.arguments
        var sockets: (Int32) -> CyderProcessTable.UnixSockets? = CyderProcessTable.unixSockets
    }

    /// nil means the process table could not be read in full; callers must
    /// then refuse the switch rather than assume nothing is running.
    static func scan(engineRoot: URL, probe: Probe = Probe()) -> [User]? {
        let root = engineRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let clients = Set(CyderProcessTable.clientImages.map { root + "/" + $0 })
        let server = root + "/bin/wineserver"
        guard let all = probe.pids() else { return nil }
        let me = getpid()
        var servers: [(prefix: String, sockets: Set<UInt64>)] = []
        var found: [Int32] = []
        for pid in all.sorted() where pid != me {
            // A process that exited meanwhile has no image; it uses nothing.
            guard let executable = probe.image(pid) else { continue }
            if executable == server {
                // wineserver never loads MoltenVK; it only names its prefix.
                if let prefix = probe.arguments(pid)?.prefix, let sockets = probe.sockets(pid) {
                    servers.append((prefix, sockets.own))
                }
            } else if clients.contains(executable) {
                found.append(pid)
            }
        }
        return found.map { pid in
            let arguments = probe.arguments(pid)
            var prefix = arguments?.prefix
            if prefix == nil, let peers = probe.sockets(pid)?.peers {
                prefix = servers.first { !$0.sockets.isDisjoint(with: peers) }?.prefix
            }
            return User(pid: pid, prefix: prefix, name: arguments?.name ?? "Windows 程序")
        }
    }

    /// `CyderSwift --runtime-users ENGINE COMPONENT`: exit 0 when unused, 75
    /// with one marker line per process on stderr when in use, 70 when the
    /// process table is unreadable.
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 4, arguments[2].hasPrefix("/"),
              ["moltenvk", "gptk"].contains(arguments[3]) else {
            FileHandle.standardError.write(Data("usage: CyderSwift --runtime-users ENGINE moltenvk|gptk\n".utf8))
            return 64
        }
        guard let users = scan(engineRoot: URL(fileURLWithPath: arguments[2])) else {
            FileHandle.standardError.write(Data("Cannot read the process list; not changing the shared \(arguments[3]) runtime.\n".utf8))
            return 70
        }
        guard !users.isEmpty else { return 0 }
        var text = "Shared \(arguments[3]) runtime is in use by running Wine processes; close them before switching.\n"
        for user in users { text += line(component: arguments[3], user) + "\n" }
        FileHandle.standardError.write(Data(text.utf8))
        return 75
    }

    static func line(component: String, _ user: User) -> String {
        var fields = ["component=\(component)", "pid=\(user.pid)"]
        if let prefix = user.prefix { fields.append("prefix=" + encode(prefix)) }
        fields.append("name=" + encode(user.name))
        return marker + " " + fields.joined(separator: " ")
    }

    struct Report: Equatable { let component: String; let users: [User] }
    /// Reads the marker lines back from a launch's captured output.
    static func report(in output: String) -> Report? {
        var component: String?
        var users: [User] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(marker + " ") {
            var fields: [String: String] = [:]
            for field in line.dropFirst(marker.count + 1).split(separator: " ") {
                guard let equals = field.firstIndex(of: "=") else { continue }
                fields[String(field[..<equals])] = String(field[field.index(after: equals)...])
            }
            guard let kind = fields["component"], component == nil || component == kind,
                  let pid = fields["pid"].flatMap(Int32.init), pid > 0 else { continue }
            component = kind
            let prefix = fields["prefix"].flatMap { $0.removingPercentEncoding }.flatMap { $0.hasPrefix("/") ? $0 : nil }
            let name = fields["name"].flatMap { $0.removingPercentEncoding } ?? "Windows 程序"
            users.append(User(pid: pid, prefix: prefix, name: name))
        }
        guard let component, !users.isEmpty else { return nil }
        return Report(component: component, users: users)
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%= ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
