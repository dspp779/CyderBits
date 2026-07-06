#!/usr/bin/env swift
// Dev helper: query or manually set/cleanup macOS handlers for .exe files.
// Cyder.app does not call this at runtime; Finder "Open With" uses Info.plist only.
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// UTIs that actually govern Windows .exe (not the overly broad public.executable).
let exeUTIs: [String] = {
    var ids = ["com.microsoft.windows-executable"]
    if let ext = UTType(filenameExtension: "exe")?.identifier {
        ids.append(ext)
    }
    return Array(Set(ids))
}()

let reportUTIs: [String] = {
    var ids = exeUTIs + ["public.executable"]
    return Array(Set(ids))
}()

let lsregisterPath =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

func defaultHandler(for uti: String) -> String? {
    LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?.takeRetainedValue() as String?
}

func defaultAppBundleIDForExeURL() -> String? {
    let url = URL(fileURLWithPath: "/tmp/cyder-assoc-test.exe") as CFURL
    guard let appURL = LSCopyDefaultApplicationURLForURL(url, .all, nil)?.takeRetainedValue() as URL? else {
        return nil
    }
    return Bundle(url: appURL)?.bundleIdentifier
}

func isAssociated(bundleID: String) -> Bool {
    if let urlBundle = defaultAppBundleIDForExeURL() {
        return urlBundle == bundleID
    }
    for uti in exeUTIs {
        if defaultHandler(for: uti) != bundleID {
            return false
        }
    }
    return !exeUTIs.isEmpty
}

func printHandlers() {
    for uti in reportUTIs.sorted() {
        let handler = defaultHandler(for: uti) ?? "(none)"
        print("\(uti)\t\(handler)")
    }
    if let urlBundle = defaultAppBundleIDForExeURL() {
        print("default_for_exe_url\t\(urlBundle)")
    } else {
        print("default_for_exe_url\t(none)")
    }
}

func runLsregister(_ flag: String, appPath: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsregisterPath)
    process.arguments = [flag, appPath]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        fputs("lsregister \(flag) failed: \(error)\n", stderr)
        return false
    }
}

func registerApp(at path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    LSRegisterURL(url, true)
    _ = runLsregister("-f", appPath: path)
}

func unregisterApp(at path: String) -> Bool {
    runLsregister("-u", appPath: path)
}

func setDefault(bundleID: String) -> Bool {
    for uti in exeUTIs {
        _ = LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, bundleID as CFString)
    }
    return isAssociated(bundleID: bundleID)
}

/// Remove Cyder from public.executable (mistaken broad binding).
func cleanupPublicExecutable(cyderBundleID: String, appPath: String?) -> Bool {
    guard defaultHandler(for: "public.executable") == cyderBundleID else {
        return true
    }
    if let path = appPath, !path.isEmpty {
        _ = unregisterApp(at: path)
        if defaultHandler(for: "public.executable") != cyderBundleID {
            return true
        }
    }
    let status = LSSetDefaultRoleHandlerForContentType(
        "public.executable" as CFString,
        .all,
        "" as CFString
    )
    return status == noErr || defaultHandler(for: "public.executable") != cyderBundleID
}

func usage() {
    fputs(
        """
        usage:
          cyder-exe-association.swift status BUNDLE_ID
          cyder-exe-association.swift set BUNDLE_ID APP_PATH
          cyder-exe-association.swift cleanup [CYDER_BUNDLE_ID] [APP_PATH]
          cyder-exe-association.swift handlers

        Cyder.app BUNDLE_ID: local.cyder.app
        Only com.microsoft.windows-executable (+ exe UTI) are set/checked for .exe.
        cleanup uses lsregister -u to drop Cyder from public.executable.

        """,
        stderr
    )
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    usage()
    exit(2)
}

let command = args[1]

switch command {
case "handlers":
    printHandlers()
    exit(0)

case "cleanup":
    let cyderID = args.count > 2 ? args[2] : "local.cyder.app"
    let appPath = args.count > 3 ? args[3] : nil
    if cleanupPublicExecutable(cyderBundleID: cyderID, appPath: appPath) {
        print("ok")
        printHandlers()
        exit(0)
    }
    fputs("failed\n", stderr)
    printHandlers()
    exit(1)

case "status", "set":
    guard args.count >= 3 else {
        usage()
        exit(2)
    }
    let bundleID = args[2]
    let appPath = args.count > 3 ? args[3] : nil

    switch command {
    case "status":
        printHandlers()
        if isAssociated(bundleID: bundleID) {
            print("associated")
            exit(0)
        }
        print("not_associated")
        exit(1)

    case "set":
        guard let path = appPath, !path.isEmpty else {
            fputs("set requires APP_PATH\n", stderr)
            usage()
            exit(2)
        }
        _ = cleanupPublicExecutable(cyderBundleID: bundleID, appPath: path)
        registerApp(at: path)
        if setDefault(bundleID: bundleID) {
            print("ok")
            printHandlers()
            exit(0)
        }
        fputs("failed\n", stderr)
        printHandlers()
        exit(1)

    default:
        break
    }

default:
    usage()
    exit(2)
}
