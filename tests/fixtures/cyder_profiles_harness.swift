import Foundation

@main
struct CyderProfilesHarness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw NSError(domain: "harness", code: 2) }
        let store = CyderProfileStore(root: URL(fileURLWithPath: args[1]))
        if args[2] == "--list" {
            for record in store.listRecords() { print("\(record.profileId) \(record.sourcePath)") }
            return
        }
        let state = store.resolve(executable: URL(fileURLWithPath: args[2]))
        switch state {
        case .uncreated(let id): print("uncreated \(id)")
        case .damaged(let id, let reason): print("damaged \(id) \(reason)")
        case .ready(let record): print("ready \(record.profileId) \(record.sourcePath)")
        }
    }
}
