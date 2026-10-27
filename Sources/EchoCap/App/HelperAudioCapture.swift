import Foundation
import AppKit

/// Captures system audio by driving a helper process.
///
/// The helper (`EchoCapCapture`) is a plain command-line program that creates
/// the Core Audio tap and streams 16 kHz mono PCM to its standard output. It
/// has to be a separate process because a tap cannot be created inside an app
/// that runs an AppKit event loop — the audio server negotiates stream usage
/// over the run loop, and the call never returns.
final class HelperAudioCapture: @unchecked Sendable {

    /// Called on a background thread with mono 16 kHz Int16 samples.
    var onSamples: (([Int16]) -> Void)?

    /// Called when the helper reports a problem.
    var onFailure: ((String) -> Void)?

    /// Called once the helper is capturing.
    var onReady: (() -> Void)?

    private var process: Process?
    private var reader: FileHandle?
    private var diagnostics: Pipe?
    /// Bytes received from the helper that do not yet form a whole frame.
    private var buffer: [UInt8] = []
    private let lock = NSLock()

    /// Whether the helper is running and streaming.
    private(set) var isRunning = false

    deinit { stop() }

    // MARK: - Lifecycle

    /// Start the helper and wait until it is capturing.
    func start(timeout: TimeInterval = 10) async throws {
        let executable = Self.helperExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CaptureError.helperMissing(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.process = process
        self.reader = outputPipe.fileHandleForReading
        self.diagnostics = errorPipe

        // Read the helper's diagnostics so failures can be reported.
        let errorReader = errorPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            readDiagnostics(errorReader)
        }

        // Read PCM frames.
        let outputReader = outputPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            readFrames(outputReader)
        }

        do {
            try process.run()
        } catch {
            throw CaptureError.helperLaunchFailed(error.localizedDescription)
        }

        // Wait for the helper to say it is capturing, but do not wait forever.
        let ready = await waitForReady(timeout: timeout)
        guard ready else {
            stop()
            throw CaptureError.startTimedOut
        }

        isRunning = true
        onReady?()
    }

    /// Stop the helper.
    func stop() {
        guard let process else { return }
        self.process = nil
        reader = nil
        diagnostics = nil
        isRunning = false
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Reading

    /// The helper signals readiness on stderr.
    private var readySignal = false

    private func readDiagnostics(_ handle: FileHandle) {
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                let message = line.replacingOccurrences(of: "[capture] ", with: "")
                if message == "capturing" {
                    lock.lock()
                    readySignal = true
                    lock.unlock()
                } else if message.hasPrefix("tap-failed")
                    || message.hasPrefix("aggregate-failed")
                    || message.hasPrefix("ioproc-failed")
                    || message.hasPrefix("start-failed")
                    || message.hasPrefix("uid-failed") {
                    let described = Self.describe(message)
                    DispatchQueue.main.async { [weak self] in
                        self?.onFailure?(described)
                    }
                }
            }
        }
    }

    private func readFrames(_ handle: FileHandle) {
        while true {
            let data = handle.availableData
            if data.isEmpty {
                // The helper exited.
                if isRunning {
                    DispatchQueue.main.async { [weak self] in
                        self?.onFailure?("采集进程意外退出")
                    }
                }
                break
            }

            lock.lock()
            buffer.append(contentsOf: data)
            lock.unlock()

            // Pull out whole frames: 4-byte little-endian length, then payload.
            while true {
                lock.lock()
                guard buffer.count >= 4 else {
                    lock.unlock()
                    break
                }
                // Read the header byte by byte. `Data` makes no alignment
                // promise, so an `UInt32` load would trap.
                let length = Int(buffer[0])
                    | Int(buffer[1]) << 8
                    | Int(buffer[2]) << 16
                    | Int(buffer[3]) << 24
                let total = 4 + length
                guard length > 0, buffer.count >= total else {
                    lock.unlock()
                    break
                }
                let payload = Array(buffer[4..<total])
                buffer.removeFirst(total)
                lock.unlock()

                // Little-endian Int16 pairs, assembled by hand for the same
                // alignment reason.
                var samples = [Int16](repeating: 0, count: payload.count / 2)
                for index in 0..<samples.count {
                    let low = UInt16(payload[index * 2])
                    let high = UInt16(payload[index * 2 + 1]) << 8
                    samples[index] = Int16(bitPattern: low | high)
                }
                if !samples.isEmpty {
                    onSamples?(samples)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Wait for the helper to report that it is capturing.
    private func waitForReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReadySignal { return true }
            if process?.isRunning == false { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Whether the helper has reported that it is capturing.
    private var isReadySignal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readySignal
    }

    /// Where the helper lives.
    static func helperExecutableURL() -> URL {
        // Inside the app bundle.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/EchoCapCapture")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // Running from a build directory.
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("EchoCapCapture")
    }

    /// Turn a helper diagnostic into something worth showing.
    private static func describe(_ message: String) -> String {
        switch message {
        case let m where m.hasPrefix("tap-failed"):
            return "无法创建系统音频 tap（\(m)）"
        case let m where m.hasPrefix("aggregate-failed"):
            return "无法创建音频聚合设备（\(m)）"
        case let m where m.hasPrefix("ioproc-failed"):
            return "无法创建音频回调（\(m)）"
        case let m where m.hasPrefix("start-failed"):
            return "无法启动音频采集（\(m)）"
        case let m where m.hasPrefix("uid-failed"):
            return "无法读取音频 tap 的标识（\(m)）"
        default:
            return message
        }
    }

    /// Errors from the helper path.
    enum CaptureError: Error, LocalizedError {
        case helperMissing(String)
        case helperLaunchFailed(String)
        case startTimedOut

        var errorDescription: String? {
            switch self {
            case .helperMissing(let path):
                return "找不到采集助手（\(path)）"
            case .helperLaunchFailed(let message):
                return "无法启动采集助手：\(message)"
            case .startTimedOut:
                return "采集助手启动超时"
            }
        }

        var recoveryHint: String? {
            switch self {
            case .startTimedOut:
                return "macOS 的音频服务可能已经卡住。重启机器（或执行 sudo killall coreaudiod）后即可恢复。"
            case .helperMissing:
                return "请重新安装 EchoCap。"
            default:
                return nil
            }
        }
    }
}
