import AudioToolbox
import CoreAudio
import DevDockDSP
import Foundation

/// Listens to everything the Mac plays (except VYNL) without changing what you hear, for live
/// transcription. A private, unmuted Core Audio process tap feeds the C capture ring; `read`
/// drains it. Separate from the EQ's tap, which mutes the originals and replays them.
///
/// Start and stop it on the main thread and read it from one other queue. Only the IO block
/// runs on the audio queue. Needs the same System Audio Recording permission as the EQ.
final class SystemAudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noOutputDevice
        case noProcessObject
        case createTap(OSStatus)
        case unsupportedFormat
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)
        case buffer

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "No output device to listen to."
            case .noProcessObject: return "Couldn't identify VYNL to keep it out of what it hears."
            case .createTap(let status): return "Couldn't start listening (tap error \(status))."
            case .unsupportedFormat: return "The Mac's audio uses a format VYNL can't listen to."
            case .createAggregate(let status): return "Couldn't start listening (device error \(status))."
            case .createIOProc(let status): return "Couldn't start listening (IO error \(status))."
            case .start(let status): return "Couldn't start listening (error \(status))."
            case .buffer: return "Couldn't set up the listening buffer."
            }
        }
    }

    private(set) var sampleRate: Double = 48_000
    private var capture: OpaquePointer?
    private var tapID = AudioDevices.unknown
    private var aggregateID = AudioDevices.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.spencermarchant.vynl.listen", qos: .userInitiated)

    deinit {
        stop()
    }

    func start() throws {
        do {
            try build()
        } catch {
            stop()
            throw error
        }
    }

    /// Safe to call more than once.
    func stop() {
        if let ioProcID, aggregateID != AudioDevices.unknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        // Let a callback already in flight finish before the buffer is freed.
        ioQueue.sync {}
        if aggregateID != AudioDevices.unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDevices.unknown
        }
        if tapID != AudioDevices.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioDevices.unknown
        }
        if let capture {
            dd_capture_destroy(capture)
            self.capture = nil
        }
    }

    /// Mono samples heard since the last call, oldest first, at `sampleRate`.
    func read(maxCount: Int) -> [Float] {
        guard let capture, maxCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: maxCount)
        let count = samples.withUnsafeMutableBufferPointer { buffer in
            dd_capture_read(capture, buffer.baseAddress, Int32(maxCount))
        }
        samples.removeLast(maxCount - Int(count))
        return samples
    }

    /// False until any sound has arrived; stays false without System Audio Recording permission.
    var hasHeardAudio: Bool {
        guard let capture else { return false }
        return dd_capture_has_heard_audio(capture) != 0
    }

    // MARK: - Private

    private func build() throws {
        guard let outputDevice = AudioDevices.defaultOutputDevice(),
              let outputUID = AudioDevices.uid(of: outputDevice)
        else { throw CaptureError.noOutputDevice }
        guard let ownProcess = AudioDevices.processObject(for: getpid()) else { throw CaptureError.noProcessObject }

        // A private stereo tap of every process except VYNL, left audible.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "VYNL Listen"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioDevices.unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == 0 else { throw CaptureError.createTap(status) }
        tapID = tap

        guard let format = AudioDevices.tapFormat(of: tap),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw CaptureError.unsupportedFormat }

        // A private aggregate device clocked by the speakers, with the tap as its input.
        // Its output is kept silent.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VYNL Listen",
            kAudioAggregateDeviceUIDKey: "com.spencermarchant.vynl.listen.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        var aggregate = AudioDevices.unknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == 0 else { throw CaptureError.createAggregate(status) }
        aggregateID = aggregate

        sampleRate = AudioDevices.nominalSampleRate(of: aggregate)
            ?? AudioDevices.nominalSampleRate(of: outputDevice)
            ?? format.mSampleRate
        guard let buffer = dd_capture_create() else { throw CaptureError.buffer }
        capture = buffer

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue, Self.makeIOBlock(buffer))
        guard status == 0, let procID else { throw CaptureError.createIOProc(status) }
        ioProcID = procID

        status = AudioDeviceStart(aggregate, procID)
        guard status == 0 else { throw CaptureError.start(status) }
    }

    /// Built in a static, nonisolated context so the block carries no actor isolation:
    /// it runs on the real-time audio queue and only calls into C.
    private static func makeIOBlock(_ capture: OpaquePointer) -> AudioDeviceIOBlock {
        return { _, inputData, _, outputData, _ in
            dd_capture_write(capture, inputData, outputData)
        }
    }
}
