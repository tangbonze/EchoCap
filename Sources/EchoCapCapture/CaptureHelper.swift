import Foundation
import CoreAudio
import AudioToolbox
import EchoCapCore

/// A helper process that captures system audio and streams it to its parent.
///
/// ## Why a separate process?
///
/// Creating the Core Audio tap has to happen in a process that is **not**
/// running an AppKit run loop. `AudioDeviceCreateIOProcID` negotiates stream
/// usage with the audio server over the run loop; when the main thread is
/// busy inside an `NSApplication` event loop that handshake never completes
/// and the call blocks forever. In a plain command-line process the same
/// sequence returns immediately.
///
/// So the GUI app spawns this helper and reads 16 kHz mono PCM frames from
/// its standard output.
///
/// ## Wire format
///
/// Each chunk is framed as a 4-byte little-endian `Int32` byte count followed
/// by that many bytes of interleaved Int16 samples. Diagnostics go to standard
/// error so they never mix into the audio stream.
enum CaptureHelper {

    static func main() {
        // A dedicated autorelease pool for the lifetime of the capture.
        let helper = Helper()
        helper.run()
    }
}

/// The capture helper.
final class Helper {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ring = SampleRing(capacity: 1 << 17)
    private var format = (sampleRate: 48_000.0, channels: 2)
    private var converter = SampleRateConverter(inputRate: 48_000, outputRate: 16_000)

    /// Whether the parent asked us to stop.
    private var running = true

    func run() {
        // Tell the parent we are alive.
        writeDiagnostic("ready (主线程=\(Thread.isMainThread))")

        writeDiagnostic("step: createTap")
        guard createTap() else { return }
        writeDiagnostic("step: createAggregate")
        guard createAggregateDevice() else { return }
        writeDiagnostic("step: createIOProc")
        guard createIOProc() else { return }
        writeDiagnostic("step: startDevice")
        guard startDevice() else { return }

        writeDiagnostic("capturing")

        // Pump the ring buffer and write frames to the parent.
        while running {
            let chunk = ring.read(max: 4096)
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let mono = converter.process(chunk, channelCount: format.channels, frameCount: chunk.count / format.channels)
            guard !mono.isEmpty else { continue }
            writeFrames(mono)
        }
    }

    // MARK: - Steps

    private func createTap() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "EchoCap Tap"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = CATapMuteBehavior.unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            writeDiagnostic("tap-failed \(status)")
            return false
        }
        return true
    }

    private func createAggregateDevice() -> Bool {
        guard let uid = readTapUID() else {
            writeDiagnostic("uid-failed")
            return false
        }

        let entry: [String: Any] = [
            kAudioSubTapUIDKey: uid,
            kAudioSubTapDriftCompensationKey: 1,
        ]
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EchoCap Capture",
            kAudioAggregateDeviceUIDKey: "com.echocap.capture.\(ProcessInfo.processInfo.processIdentifier)",
            kAudioAggregateDeviceTapListKey: [entry],
            kAudioAggregateDeviceIsPrivateKey: true,
        ]

        let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregateID)
        guard status == noErr else {
            writeDiagnostic("aggregate-failed \(status)")
            return false
        }

        // The tap's native format decides the resampling ratio.
        if let asbd = readTapFormat() {
            format.sampleRate = asbd.mSampleRate
            format.channels = Int(asbd.mChannelsPerFrame)
            converter = SampleRateConverter(
                inputRate: asbd.mSampleRate,
                outputRate: 16_000
            )
        }
        return true
    }

    private func createIOProc() -> Bool {
        // Two details matter here:
        //
        // - The client-data pointer has to be nil. A non-nil one leaves the
        //   stream-usage handshake waiting forever.
        // - The callback has to be a plain global function, not a closure
        //   literal. Swift bridges a closure to a C function pointer through a
        //   context, and the audio server never completes the handshake with
        //   one.
        let status = AudioDeviceCreateIOProcID(aggregateID, captureIOProc, nil, &ioProcID)

        guard status == noErr else {
            writeDiagnostic("ioproc-failed \(status)")
            return false
        }
        return true
    }

    private func startDevice() -> Bool {
        guard let ioProcID else { return false }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            writeDiagnostic("start-failed \(status)")
            return false
        }
        return true
    }

    // MARK: - Realtime path

    /// The one live helper, so the realtime callback can find the ring.
    nonisolated(unsafe) static var current: Helper?

    fileprivate func handleRealtime(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            ring.write(data.assumingMemoryBound(to: Float.self), count: count)
        }
    }

    // MARK: - Output

    private func writeFrames(_ samples: [Int16]) {
        var header = UInt32(samples.count * 2).littleEndian
        var bytes = Data()
        bytes.append(Data(bytes: &header, count: 4))
        samples.withUnsafeBufferPointer { buffer in
            bytes.append(Data(buffer: buffer))
        }
        FileHandle.standardOutput.write(bytes)
    }

    private func writeDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("[capture] \(message)\n".utf8))
    }

    /// Destroy aggregate devices this app left behind earlier.
    ///
    /// A process that is killed outright cannot clean up after itself, and the
    /// leftovers make the audio server progressively less willing to hand out
    /// new taps.
    @discardableResult
    static func removeStaleAggregateDevices() -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x64657623,          // 'dev#'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return 0 }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return 0 }

        var removed = 0
        for id in ids {
            var uid: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: 0x75696420,        // 'uid '
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            let identifier = uid as String
            guard identifier.hasPrefix("com.echocap.capture.") else { continue }
            if AudioHardwareDestroyAggregateDevice(id) == noErr {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Tap properties

    private func readTapUID() -> String? {
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74756964,          // 'tuid'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid as String
    }

    private func readTapFormat() -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: 0x74666D74,          // 'tfmt'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }
        return asbd
    }
}

/// The realtime callback.
///
/// A plain global function rather than a closure: see `createIOProc`.
func captureIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    Helper.current?.handleRealtime(inputData)
    return noErr
}

/// Single-producer / single-consumer lock-free ring of floats.
final class SampleRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = max(1024, capacity)
        self.storage = .allocate(capacity: self.capacity)
        self.storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Realtime thread. Never blocks.
    func write(_ source: UnsafePointer<Float>, count count: Int) {
        guard count > 0 else { return }
        var written = 0
        while written < count {
            if self.count == capacity {
                readIndex = (readIndex + 1) % capacity
                self.count -= 1
            }
            let chunk = min(count - written, capacity - writeIndex)
            (storage + writeIndex).update(from: source + written, count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            self.count += chunk
            written += chunk
        }
    }

    /// Worker thread.
    func read(max limit: Int) -> [Float] {
        let take = min(count, limit)
        guard take > 0 else { return [] }
        var out = [Float](repeating: 0, count: take)
        let first = min(take, capacity - readIndex)
        out.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: storage + readIndex, count: first)
            if first < take {
                destination.baseAddress!.advanced(by: first).update(from: storage, count: take - first)
            }
        }
        readIndex = (readIndex + take) % capacity
        count -= take
        return out
    }
}
