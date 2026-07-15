import Foundation

enum CyderProfileState {
    case uncreated(profileID: String)
    case damaged(profileID: String, reason: String)
    case ready(CyderProfileRecord)
}

struct CyderProfileRecord: Codable, Equatable {
    let schemaVersion: Int
    let profileId: String
    let sourcePath: String
    let baseTemplate: String
    let recipeId: String?
    let legacy: Bool?
    let layoutVersion: Int
}

enum CyderProfileError: LocalizedError {
    case executableMissing(String)
    case canonicalizationFailed(String)
    case profileIDUnavailable

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path): return "EXE 不存在：\(path)"
        case .canonicalizationFailed(let path): return "無法取得 EXE 的 canonical path：\(path)"
        case .profileIDUnavailable: return "無法使用 SHA-256 計算 Profile ID"
        }
    }
}

final class CyderProfileStore {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Enumerate only complete, non-symlinked profile records. Damaged entries
    /// are intentionally omitted from the settings list; selecting an EXE
    /// still uses `resolve` to present a precise damaged/uncreated reason.
    func listRecords() -> [CyderProfileRecord] {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        guard isDirectory(profiles), !isSymlink(profiles),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: profiles, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.compactMap { (directory: URL) -> CyderProfileRecord? in
            guard !isSymlink(directory), isDirectory(directory) else { return nil }
            let recordID = directory.lastPathComponent
            guard recordID.range(of: "^profile-[0-9a-f]{24}$", options: .regularExpression) != nil else { return nil }
            let bottle = root.appendingPathComponent("bottles", isDirectory: true)
                .appendingPathComponent(recordID, isDirectory: true)
            guard !isSymlink(bottle), isDirectory(bottle) else { return nil }
            let metadata = directory.appendingPathComponent("profile.json")
            guard !isSymlink(metadata), FileManager.default.fileExists(atPath: metadata.path),
                  let data = try? Data(contentsOf: metadata),
                  let record = try? JSONDecoder().decode(CyderProfileRecord.self, from: data),
                  record.schemaVersion == 1, record.layoutVersion == 1,
                  record.profileId == recordID,
                  ["pristine", "recommended"].contains(record.baseTemplate),
                  !record.sourcePath.isEmpty,
                  FileManager.default.fileExists(atPath: record.sourcePath),
                  let sourceID = try? self.profileID(for: URL(fileURLWithPath: record.sourcePath)),
                  sourceID == recordID,
                  record.recipeId == nil || record.recipeId!.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
                return nil
            }
            return record
        }.sorted { lhs, rhs in
            lhs.sourcePath.localizedStandardCompare(rhs.sourcePath) == .orderedAscending
        }
    }

    func canonicalExecutablePath(_ executable: URL) throws -> String {
        let path = executable.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw CyderProfileError.executableMissing(path)
        }
        let directory = executable
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard !directory.isEmpty, !executable.lastPathComponent.isEmpty else {
            throw CyderProfileError.canonicalizationFailed(path)
        }
        return directory + "/" + executable.lastPathComponent
    }

    func profileID(for executable: URL) throws -> String {
        let canonical = try canonicalExecutablePath(executable)
        guard let digest = Self.sha256(canonical) else {
            throw CyderProfileError.profileIDUnavailable
        }
        return "profile-" + String(digest.prefix(24))
    }

    func resolve(executable: URL) -> CyderProfileState {
        do {
            let canonical = try canonicalExecutablePath(executable)
            let id = try profileID(for: executable)
            let profile = root.appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            let bottle = root.appendingPathComponent("bottles", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            let profileExists = FileManager.default.fileExists(atPath: profile.path) || isSymlink(profile)
            let bottleExists = FileManager.default.fileExists(atPath: bottle.path) || isSymlink(bottle)
            guard profileExists || bottleExists else { return .uncreated(profileID: id) }
            guard !isSymlink(profile), !isSymlink(bottle) else {
                return .damaged(profileID: id, reason: "profile 或 bottle 不得為 symlink")
            }
            guard isDirectory(profile), isDirectory(bottle) else {
                return .damaged(profileID: id, reason: "profile 與 bottle 必須是 directory")
            }
            guard profileExists, bottleExists else {
                return .damaged(profileID: id, reason: "profile.json 與 bottle 必須同時存在")
            }
            let metadataURL = profile.appendingPathComponent("profile.json")
            guard !isSymlink(metadataURL) else {
                return .damaged(profileID: id, reason: "profile.json 不得為 symlink")
            }
            guard FileManager.default.fileExists(atPath: metadataURL.path) else {
                return .damaged(profileID: id, reason: "缺少 profile.json")
            }
            let record: CyderProfileRecord
            do {
                let data = try Data(contentsOf: metadataURL)
                record = try JSONDecoder().decode(CyderProfileRecord.self, from: data)
            } catch {
                return .damaged(profileID: id, reason: "profile.json 無法解析：\(error.localizedDescription)")
            }
            guard record.schemaVersion == 1, record.layoutVersion == 1 else {
                return .damaged(profileID: id, reason: "不支援的 metadata schema/layout")
            }
            guard record.profileId == id else {
                return .damaged(profileID: id, reason: "profileId 與 canonical EXE 不一致")
            }
            guard record.sourcePath == canonical else {
                return .damaged(profileID: id, reason: "sourcePath 與 canonical EXE 不一致")
            }
            guard ["pristine", "recommended"].contains(record.baseTemplate) else {
                return .damaged(profileID: id, reason: "baseTemplate 不合法")
            }
            if let recipeId = record.recipeId,
               recipeId.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
                return .damaged(profileID: id, reason: "recipeId 不合法")
            }
            return .ready(record)
        } catch let error as CyderProfileError {
            return .damaged(profileID: "unknown", reason: error.localizedDescription)
        } catch {
            return .damaged(profileID: "unknown", reason: error.localizedDescription)
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return values.isDirectory == true
    }

    private static func sha256(_ value: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256"]
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if let input = process.standardInput as? Pipe {
                input.fileHandleForWriting.write(Data(value.utf8))
                input.fileHandleForWriting.closeFile()
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let digest = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
            return digest.lowercased()
        } catch {
            return nil
        }
    }
}
