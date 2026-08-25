import Foundation

enum CyderRosetta {
    static var isAppleSilicon: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
        process.arguments = ["-m"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let machine = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return machine == "arm64"
    }

    static var isInstalled: Bool {
        let pkg = Process()
        pkg.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        pkg.arguments = ["--pkg-info", "com.apple.pkg.RosettaUpdateAuto"]
        pkg.standardOutput = FileHandle.nullDevice
        pkg.standardError = FileHandle.nullDevice
        do {
            try pkg.run()
            pkg.waitUntilExit()
            if pkg.terminationStatus == 0 { return true }
        } catch {}

        let arch = Process()
        arch.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        arch.arguments = ["-x86_64", "/usr/bin/true"]
        arch.standardOutput = FileHandle.nullDevice
        arch.standardError = FileHandle.nullDevice
        do {
            try arch.run()
            arch.waitUntilExit()
            return arch.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Caller must have obtained informed consent in the UI.
    static func installWithAgreedLicense() -> (ok: Bool, detail: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["--install-rosetta", "--agree-to-license"]
        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "failed to start softwareupdate: \(error.localizedDescription)")
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let combined = String(data: outData + errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return (false, combined.isEmpty
                ? "softwareupdate exit \(process.terminationStatus)"
                : combined)
        }
        if !isInstalled {
            return (false, combined.isEmpty
                ? "Rosetta install reported success but verification failed"
                : combined)
        }
        return (true, combined)
    }
}
