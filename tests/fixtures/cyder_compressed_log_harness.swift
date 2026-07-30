import Foundation

@main
struct CyderCompressedLogHarness {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try CyderCompressedLogWriter(outputURL: output)
        let data = Data(repeating: 65, count: 256 * 1024)
        try writer.write(data)
        writer.closeInput(waitForExit: true)
        guard FileManager.default.fileExists(atPath: output.path) else {
            exit(1)
        }
    }
}
