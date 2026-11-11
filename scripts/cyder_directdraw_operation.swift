import Foundation
import Darwin

/// One physical helper owner across options windows. A read deadline/cancel
/// revokes its result, but ownership lasts until the actual process exits.
/// Mutations keep running and retain their output after an observation deadline.
final class CyderDirectDrawOperations {
    enum Update {
        case completed(Result<[String: Any], Error>)
        case stillRunning
    }
    static let shared = CyderDirectDrawOperations()
    static func helperEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !["CYDER_DDRAW_PATH", "CNC_DDRAW_CONFIG_FILE"].contains($0.key.uppercased()) }
    }
    private final class Operation {
        let id: UUID
        let process: Process
        let pipe: Pipe
        let readOnly: Bool
        var callback: ((Update) -> Void)?
        var runnerID: UUID?
        var source: DispatchSourceRead?
        var data = Data()
        var outputError: Error?
        var outcome: CyderProcessRunner.Outcome?
        var spawned = false
        var readFinished = false
        init(id: UUID, process: Process, pipe: Pipe, readOnly: Bool, callback: @escaping (Update) -> Void) {
            self.id = id; self.process = process; self.pipe = pipe; self.readOnly = readOnly; self.callback = callback
        }
    }
    private let queue = DispatchQueue(label: "local.cyder.directdraw-operation", qos: .userInitiated)
    private let delivery: DispatchQueue
    private let statusDeadline: TimeInterval
    private let mutationDeadline: TimeInterval
    private let makeProcess: (String, URL, String?) -> Process
    private let beforeSpawn: () -> Void
    private lazy var runner = CyderProcessRunner(delivery: queue, beforeSpawn: beforeSpawn)
    private var active: Operation?
    private static let outputLimit = 65_536

    init(delivery: DispatchQueue = .main, statusDeadline: TimeInterval = 10,
         mutationDeadline: TimeInterval = 30,
         beforeSpawn: @escaping () -> Void = {},
         makeProcess: @escaping (String, URL, String?) -> Process = { command, executable, argument in
             let process = Process()
             process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
             let helper = Bundle.main.resourceURL?.appendingPathComponent("ogom-scripts/cyder-cnc-game.rb")
             process.arguments = [helper?.path ?? "", command, executable.path] + (argument.map { [$0] } ?? [])
             process.environment = CyderDirectDrawOperations.helperEnvironment(ProcessInfo.processInfo.environment)
             return process
         }) {
        self.delivery = delivery; self.statusDeadline = statusDeadline
        self.mutationDeadline = mutationDeadline; self.beforeSpawn = beforeSpawn; self.makeProcess = makeProcess
    }

    @discardableResult
    func run(_ command: String, executable: URL, argument: String? = nil,
             completion: @escaping (Update) -> Void) -> UUID {
        let id = UUID()
        queue.async { [self] in
            guard active == nil else {
                delivery.async { completion(.completed(.failure(Self.error("前一項 DirectDraw 作業尚未結束。請稍候再重新檢查。")))) }
                return
            }
            guard ["status", "enable", "disable", "restore", "recover"].contains(command) else {
                delivery.async { completion(.completed(.failure(Self.error("無法辨識 DirectDraw 操作。")))) }
                return
            }
            let readOnly = command == "status"
            let process = makeProcess(command, executable, argument), pipe = Pipe()
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
                delivery.async { completion(.completed(.failure(Self.error("無法準備 DirectDraw 狀態讀取。")))) }
                return
            }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = pipe
            let operation = Operation(id: id, process: process, pipe: pipe, readOnly: readOnly, callback: completion)
            active = operation
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            operation.source = source
            let readHandle = pipe.fileHandleForReading
            source.setCancelHandler { try? readHandle.close() }
            source.setEventHandler { [weak self, weak operation] in
                guard let self, let operation else { return }
                self.drain(operation)
            }
            source.resume()
            let deadline = command == "status" ? statusDeadline : mutationDeadline
            operation.runnerID = runner.run(process: process, policy: readOnly ? .observation : .mutation,
                deadline: deadline, onSpawn: { [weak operation] _ in
                    operation?.spawned = true
                    try? operation?.pipe.fileHandleForWriting.close()
                }, onRelease: { [self, operation] in finish(operation) }) { [self, operation] outcome in
                    operation.outcome = outcome
                    if outcome == .unconfirmed {
                        if operation.readOnly {
                            complete(operation, .failure(Self.error("DirectDraw 讀取超過等待時間，狀態尚未確認。請檢查檔案位置或 macOS 的檔案存取提示，再重新檢查。")))
                        } else if let callback = operation.callback {
                            delivery.async { callback(.stillRunning) }
                        }
                    }
                }
        }
        return id
    }

    /// Closing a window cancels only status, never a settings or legacy-file mutation.
    func cancelRead(_ id: UUID) {
        queue.async { [self] in
            guard let operation = active, operation.id == id, operation.readOnly else { return }
            operation.callback = nil
            if let runnerID = operation.runnerID { runner.cancelObservation(runnerID) }
        }
    }

    func inspect(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in let busy = active != nil; delivery.async { completion(busy) } }
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "CyderDirectDraw", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func complete(_ operation: Operation, _ result: Result<[String: Any], Error>) {
        guard let callback = operation.callback else { return }
        operation.callback = nil
        delivery.async { callback(.completed(result)) }
    }

    private func drain(_ operation: Operation) {
        guard active === operation, !operation.readFinished else { return }
        // Nonblocking and capped per turn: neither a silent child, a descendant
        // holding stdout open, nor unlimited output can occupy a worker forever.
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = Darwin.read(operation.pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                if operation.outputError != nil { continue }
                if operation.data.count + count <= Self.outputLimit {
                    operation.data.append(contentsOf: bytes.prefix(count))
                } else {
                    operation.outputError = Self.error("DirectDraw 回應過大，無法確認結果。請重新檢查目前狀態。")
                    if operation.readOnly {
                        complete(operation, .failure(operation.outputError!))
                        if let id = operation.runnerID { runner.cancelObservation(id) }
                    }
                }
            } else if count == 0 {
                operation.readFinished = true
                operation.source?.cancel(); return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                operation.outputError = Self.error("無法讀取 DirectDraw 回應，狀態尚未確認。")
                operation.readFinished = true
                operation.source?.cancel(); return
            }
        }
    }

    private func finish(_ operation: Operation) {
        guard active === operation else { return }
        drain(operation)
        operation.readFinished = true
        operation.source?.cancel(); operation.source = nil
        try? operation.pipe.fileHandleForWriting.close()
        active = nil
        guard operation.callback != nil else { return }
        if let error = operation.outputError { complete(operation, .failure(error)); return }
        if case .failedToStart(let message) = operation.outcome {
            complete(operation, .failure(Self.error(message))); return
        }
        guard operation.spawned else {
            complete(operation, .failure(Self.error("DirectDraw 操作未啟動。"))); return
        }
        guard operation.process.terminationReason == .exit, operation.process.terminationStatus == 0,
              let value = try? JSONSerialization.jsonObject(with: operation.data) as? [String: Any] else {
            let text = String(decoding: operation.data.prefix(1800), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            complete(operation, .failure(Self.error(text.isEmpty ? "無法確認 DirectDraw 操作結果。請重新檢查。" : text)))
            return
        }
        complete(operation, .success(value))
    }
}
