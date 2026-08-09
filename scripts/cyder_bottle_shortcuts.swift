import Foundation

/// One Windows Start Menu / Desktop shortcut that points at a launchable EXE.
struct CyderBottleShortcut: Equatable {
    let linkPath: String
    let windowsTarget: String
    let displayName: String
}

/// Scans a Wine prefix for `.lnk` files and resolves Shell Link LocalBasePath
/// without starting Wine. Used to auto-populate the Cyder game library.
enum CyderBottleShortcutScanner {
    private static let skipNameTokens = [
        "uninstall", "uninst", "remove", "help", "readme", "website",
        "manual", "support", "url", "documentation",
    ]

    static func discover(prefix: URL = CyderPaths.sharedBottle) -> [CyderBottleShortcut] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var roots: [URL] = [
            driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu", isDirectory: true),
        ]
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: users,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for user in entries {
                roots.append(user.appendingPathComponent("Desktop", isDirectory: true))
                roots.append(
                    user.appendingPathComponent(
                        "AppData/Roaming/Microsoft/Windows/Start Menu",
                        isDirectory: true
                    )
                )
            }
        }

        var seenTargets = Set<String>()
        var results: [CyderBottleShortcut] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "lnk" else { continue }
                guard let target = localBasePath(in: fileURL) else { continue }
                let normalized = target.replacingOccurrences(of: "/", with: "\\")
                guard normalized.lowercased().hasSuffix(".exe") else { continue }
                let leaf = URL(fileURLWithPath: normalized.replacingOccurrences(of: "\\", with: "/"))
                    .deletingPathExtension()
                    .lastPathComponent
                    .lowercased()
                if skipNameTokens.contains(where: { leaf.contains($0) }) { continue }
                let key = normalized.lowercased()
                guard seenTargets.insert(key).inserted else { continue }
                let display = URL(fileURLWithPath: fileURL.deletingPathExtension().path).lastPathComponent
                results.append(
                    CyderBottleShortcut(
                        linkPath: fileURL.path,
                        windowsTarget: normalized,
                        displayName: display.isEmpty ? leaf : display
                    )
                )
            }
        }
        return results.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Converts `C:\Program Files\…\game.exe` into a host path under `prefix/drive_c`.
    static func hostExecutableURL(windowsTarget: String, prefix: URL = CyderPaths.sharedBottle) -> URL? {
        var path = windowsTarget.replacingOccurrences(of: "/", with: "\\")
        if let colon = path.firstIndex(of: ":") {
            path = String(path[path.index(after: colon)...])
        }
        while path.hasPrefix("\\") { path.removeFirst() }
        guard !path.isEmpty else { return nil }
        let relative = path.replacingOccurrences(of: "\\", with: "/")
        let url = prefix
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent(relative)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Minimal Shell Link parser: LinkFlags + LinkInfo.LocalBasePath (ANSI).
    static func localBasePath(in linkURL: URL) -> String? {
        guard let data = try? Data(contentsOf: linkURL), data.count >= 0x4C else { return nil }
        // HeaderSize / CLSID check is soft; require ShellLink magic dword.
        guard data[0] == 0x4C, data[1] == 0x00, data[2] == 0x00, data[3] == 0x00 else { return nil }
        let flags = readUInt32(data, 0x14)
        var offset = 0x4C
        if flags & 0x1 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let idListSize = Int(readUInt16(data, offset))
            offset += 2 + idListSize
        }
        guard flags & 0x2 != 0, offset + 0x1C <= data.count else { return nil }
        let linkInfoFlags = readUInt32(data, offset + 8)
        let localBaseOffset = Int(readUInt32(data, offset + 16))
        guard linkInfoFlags & 0x1 != 0, localBaseOffset > 0 else { return nil }
        let pathOffset = offset + localBaseOffset
        guard pathOffset < data.count else { return nil }
        // LocalBasePath is null-terminated ANSI in classic LinkInfo.
        var end = pathOffset
        while end < data.count, data[end] != 0 { end += 1 }
        guard end > pathOffset else { return nil }
        return String(data: data.subdata(in: pathOffset..<end), encoding: .isoLatin1)
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 2))
        }
        return UInt16(littleEndian: value)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}
