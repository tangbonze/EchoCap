import Foundation
import CoreAudio
import AudioToolbox
import EchoCapCore

/// Property selectors for the Core Audio process tap API.
///
/// These are not exposed in the public SDK headers, but they are the documented
/// four-character codes the HAL expects for tap objects.
enum TapProperty {
    /// `kAudioTapPropertyUID` — the tap's stable identifier.
    static let uid = AudioObjectPropertySelector(0x74756964) // 'tuid'
    /// `kAudioTapPropertyFormat` — the tap's native stream format.
    static let format = AudioObjectPropertySelector(0x74666D74) // 'tfmt'
}

/// Captures whatever the Mac is playing, system-wide.
///
/// The pipeline mirrors Apple's reference implementation:
///
/// 1. Create a global process tap.
/// 2. Wrap it in a private aggregate device (this is what gives the tap an IO path).
/// 3. Attach an IOProc to the aggregate device and read frames on the realtime thread.
///
/// The realtime callback only copies samples — no allocation, no locks — into a
/// lock-free ring buffer that a worker thread drains.
final class SystemAudioCapture: @unchecked Sendable {

    struct Format {
        var sampleRate: Double
        var channelCount: Int
        var isFloat: Bool

        static let unknown = Format(sampleRate: 48_000, channelCount: 2, isFloat: true)
    }

    enum CaptureError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case tapUIDUnavailable
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
        case startTimedOut
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "无法创建系统音频 tap（错误码 \(s)）"
            case .tapUIDUnavailable: return "无法读取 tap 的 UID"
            case .aggregateCreationFailed(let s): return "无法创建聚合设备（错误码 \(s)）"
            case .ioProcCreationFailed(let s): return "无法创建 IOProc（错误码 \(s)）"
            case .startFailed(let s): return "无法启动音频采集（错误码 \(s)）"
            case .startTimedOut: return "启动音频采集超时"
            case .microphoneUnavailable: return "麦克风不可用"
            }
        }

        /// A short, actionable hint for the most common failure.
        var recoveryHint: String? {
            switch self {
            case .startFailed, .startTimedOut:
                return "系统可能没有可用的音频输出设备（屏幕锁定或输出设备被占用时会出现）。可先在菜单里改用麦克风。"
            default:
                return nil
            }
        }
    }

    /// Called on a worker thread with mono 16 kHz Int16 samples.
    var onSamples: (([Int16]) -> Void)?

    /// Optional trace of each startup step.
    var onTrace: ((String) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var ring: SampleRing?
    private var converter: SampleRateConverter?
    private var worker: Thread?
    private var running = false
    private let lock = NSLock()

    private(set) var format = Format.unknown

    /// UID of the aggregate device, which must be unique per capture session.
    private let aggregateUID: String

    init(aggregateUID: String = "com.echocap.aggregate.\(UUID().uuidString)") {
        self.aggregateUID = aggregateUID
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        // 1. Global tap over every process that plays audio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "EchoCap Tap"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        onTrace?("1. 创建 tap")
        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw CaptureError.tapCreationFailed(tapStatus) }
        tapID = newTapID

        // 2. The tap's UID and native format.
        onTrace?("2. 读取 tap UID")
        guard let tapUID = readTapUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.tapUIDUnavailable
        }

        let nativeFormat = readTapFormat()
        format = nativeFormat
        converter = SampleRateConverter(
            inputRate: nativeFormat.sampleRate > 0 ? nativeFormat.sampleRate : 48_000,
            outputRate: 16_000
        )

        // 3. A private aggregate device gives the tap an input stream to read.
        let entry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1,
        ]
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EchoCap Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: [entry],
            kAudioAggregateDeviceIsPrivateKey: true,
        ]

        onTrace?("3. 创建聚合设备")
        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = newAggregateID

        // 4. Attach the realtime IOProc.
        let ring = SampleRing(capacity: 1 << 16)
        self.ring = ring

        onTrace?("4. 创建 IOProc")
        var newIOProcID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcID(aggregateID, tapIOProc, Unmanaged.passUnretained(self).toOpaque(), &newIOProcID)
        guard ioProcStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.ioProcCreationFailed(ioProcStatus)
        }
        ioProcID = newIOProcID

        onTrace?("5. 启动设备")
        let startStatus = AudioDeviceStart(aggregateID, newIOProcID!)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, newIOProcID!)
            ioProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw CaptureError.startFailed(startStatus)
        }

        onTrace?("6. 启动工作线程")
        running = true
        startWorker()
    }

    /// Start the capture off the main thread.
    ///
    /// Core Audio calls can block for a long time when the audio server is
    /// unhappy — for instance when the machine has no usable output device.
    /// Doing that on the main thread would freeze the whole app, so the setup
    /// happens on a private queue and the caller waits with a timeout.
    func startAsync(timeout: TimeInterval = 8) async throws {
        let box = SetupBox()
        setupQueue.async { [self] in
            do {
                try start()
                box.finish(.success(()))
            } catch {
                box.finish(.failure(error))
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.attach(continuation)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    box.finish(.failure(CaptureError.startTimedOut))
                }
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }

    /// Serial queue used for capture setup.
    private let setupQueue = DispatchQueue(label: "com.echocap.capture.setup")

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false

        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        ring = nil
        converter = nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Realtime callback

    /// Called by Core Audio on the realtime thread. Must not allocate or lock.
    private let tapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let capture = Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue()
        capture.handleRealtime(inputData)
        return noErr
    }

    private func handleRealtime(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let ring else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            ring.write(data.assumingMemoryBound(to: Float.self), count: count)
        }
    }

    // MARK: - Worker

    private func startWorker() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            while self.isRunning {
                guard let ring = self.ring else { break }
                let chunk = ring.read(available: 4096)
                if chunk.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                self.emit(chunk)
            }
        }
        thread.name = "com.echocap.capture.worker"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    private func emit(_ interleaved: [Float]) {
        guard let converter else { return }
        let channels = max(1, format.channelCount)
        let frames = interleaved.count / channels
        let mono16k = converter.process(interleaved, channelCount: channels, frameCount: frames)
        guard !mono16k.isEmpty else { return }
        onSamples?(mono16k)
    }

    // MARK: - Tap introspection

    private func readTapUID() -> String? {
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: TapProperty.uid,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    private func readTapFormat() -> Format {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: TapProperty.format,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return .unknown }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return Format(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            isFloat: isFloat
        )
    }
}

/// Single-producer / single-consumer lock-free ring of floats.
///
/// The realtime thread only ever calls `write`, the worker only ever calls
/// `read`, so no locking is needed on the audio path.
final class SampleRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var available: Int = 0

    init(capacity: Int) {
        self.capacity = max(1024, capacity)
        self.storage = .allocate(capacity: self.capacity)
        self.storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Realtime thread. Never blocks; drops the oldest data if the worker falls behind.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var written = 0
        while written < count {
            let space = capacity - available
            if space == 0 {
                // Consumer is behind: overwrite the oldest sample to stay live.
                readIndex = (readIndex + 1) % capacity
                available -= 1
            }
            let chunk = min(count - written, capacity - writeIndex)
            (storage + writeIndex).update(from: source + written, count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            available += chunk
            written += chunk
        }
    }

    /// Worker thread.
    func read(available maxCount: Int) -> [Float] {
        let count = min(available, maxCount)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let firstChunk = min(count, capacity - readIndex)
        out.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: storage + readIndex, count: firstChunk)
            if firstChunk < count {
                dst.baseAddress!.advanced(by: firstChunk)
                    .update(from: storage, count: count - firstChunk)
            }
        }
        readIndex = (readIndex + count) % capacity
        available -= count
        return out
    }
}


/// Resumes a waiting continuation exactly once.
private final class SetupBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private let lock = NSLock()

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
