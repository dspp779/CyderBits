#!/usr/bin/env swift
// Query or set the default macOS handler for .exe files.
import CoreServices
import Foundation
import UniformTypeIdentifiers

let exeUTIs: [String] = {
    var ids = ["com.microsoft.windows-executable", "public.executable"]
    if let ext = UTType(filenameExtension: "exe")?.identifier {
        ids.append(ext)
    }
    return Array(Set(ids))
}()

func defaultHandler(for uti: String) -> String? {
    LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all)?.takeRetainedValue() as String?
}

func isAssociated(bundleID: String) -> Bool {
    for uti in exeUTIs {
        if let handler = defaultHandler(for: uti), handler == bundleID {
            return true
        }
    }
    return false
}

func registerApp(at path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    LSRegisterURL(url, true)
}

func setDefault(bundleID: String) -> Bool {
    var anyOK = false
    for uti in exeUTIs {
        let status = LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, bundleID as CFString)
        if status == noErr {
            anyOK = true
        }
    }
    return anyOK && isAssociated(bundleID: bundleID)
}

func usage() {
    fputs(
        """
        usage:
          cyder-exe-association.swift status BUNDLE_ID
          cyder-exe-association.swift set BUNDLE_ID [APP_PATH]

        """,
        stderr
    )
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    usage()
    exit(2)
}

let command = args[1]
let bundleID = args[2]
let appPath = args.count > 3 ? args[3] : nil

switch command {
case "status":
    if isAssociated(bundleID: bundleID) {
        print("associated")
        exit(0)
    }
    for uti in exeUTIs {
        if let handler = defaultHandler(for: uti) {
            print("current_uti=\(uti)")
            print("current_handler=\(handler)")
            break
        }
    }
    print("not_associated")
    exit(1)

case "set":
    if let path = appPath, !path.isEmpty {
        registerApp(at: path)
    }
    if setDefault(bundleID: bundleID) {
        print("ok")
        exit(0)
    }
    fputs("failed\n", stderr)
    exit(1)

default:
    usage()
    exit(2)
}
