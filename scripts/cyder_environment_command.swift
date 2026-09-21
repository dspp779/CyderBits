import Foundation

/// Read-only shell guard adapter. A successful root wait or an old socket is
/// never enough to release the sync/power reservation of a shared environment.
enum CyderEnvironmentCommand {
    static func run(arguments: [String],
                    identify: (URL, URL) -> CyderEnvironmentProbe.Identity? = { CyderEnvironmentProbe.identify(prefix: $0, engine: $1) },
                    probe: (CyderEnvironmentProbe.Identity) -> CyderEnvironmentProbe.Result = { CyderEnvironmentProbe.inspect($0) },
                    pause: () -> Void = { Thread.sleep(forTimeInterval: 0.5) },
                    output: (String) -> Void = { print($0) }) -> Int32 {
        guard arguments.count == 4, arguments[1] == "--environment-state",
              arguments[2].hasPrefix("/"), arguments[3].hasPrefix("/"),
              let identity = identify(URL(fileURLWithPath: arguments[2]), URL(fileURLWithPath: arguments[3])) else { return 64 }
        switch probe(identity) {
        case .alive: output("cyder-environment-v1 alive"); return 0
        case .unknown: return 75
        case .empty:
            pause()
            guard identify(URL(fileURLWithPath: arguments[2]), URL(fileURLWithPath: arguments[3])) == identity else { return 75 }
            guard case .empty = probe(identity) else { return 75 }
            output("cyder-environment-v1 empty"); return 10
        }
    }
}
