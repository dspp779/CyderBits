import Foundation

@main
enum CyderGameLibraryHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("usage: harness SUPPORT EXE_A EXE_B")
        }
        let support = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let firstURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let secondURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let libraryURL = support.appendingPathComponent("game-library.json")
        let profiles = CyderProfileStore(root: support)
        let library = CyderGameLibraryStore(url: libraryURL, profileStore: profiles)

        let first = try library.add(executable: firstURL)
        precondition(first.displayName == "測試遊戲")
        _ = try library.add(executable: firstURL)
        precondition(library.games.count == 1)

        _ = try library.add(executable: secondURL)
        precondition(library.games.count == 2)

        let reloaded = CyderGameLibraryStore(url: libraryURL, profileStore: profiles)
        precondition(reloaded.games.count == 2)
        let expectedPaths = try Set([
            profiles.canonicalExecutablePath(firstURL),
            profiles.canonicalExecutablePath(secondURL),
        ])
        precondition(Set(reloaded.games.map(\.executablePath)) == expectedPaths)

        try reloaded.remove(id: first.id)
        precondition(reloaded.games.count == 1)
        print("cyder game library harness: ok")
    }
}
