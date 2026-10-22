import AudioToolbox
import CoreAudio
import DevDockDSP
import Foundation

/// The system-wide EQ. A Core Audio process tap captures every app's audio (muting the
/// originals), the C equalizer processes it, and a private aggregate device plays the result
/// on the real speakers. Pattern from Apple's "Capturing system audio with Core Audio taps".
///
/// Create, start and stop it on the main thread. Only the render block runs on the audio queue.
final class ProcessTapEngine {
    enum EngineError: LocalizedError {
        case noOutputDevice
        case noProcessObject
        case createTap(OSStatus)
        case unsupportedFormat
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)
        case dsp

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "No output device to play through."
            case .noProcessObject: return "Couldn't identify VYNL to keep it out of its own tap."
            case .createTap(let status): return "Couldn't create the audio tap (error \(status))."
            case .unsupportedFormat: return "The audio tap uses a format the EQ doesn't handle."
            case .createAggregate(let status): return "Couldn't set up the EQ's audio device (error \(status))."
            case .createIOProc(let status): return "Couldn't attach the EQ to the audio device (error \(status))."
            case .start(let status): return "Couldn't start the EQ (error \(status))."
            case .dsp: return "Couldn't create the equalizer."
            }
        }
    }

    let outputDevice: AudioDeviceID
    private(set) var equalizer: OpaquePointer?
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioDevices.unknown
    private var aggregateID = AudioDevices.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let renderQueue = DispatchQueue(label: "com.spencermarchant.devdock.render", qos: .userInteractive)

    init(outputDevice: AudioDeviceID) {
        self.outputDevice = outputDevice
    }

    deinit {
        stop()
    }

    func start(gains: [Float], preamp: Float) throws {
        do {
            try build(gains: gains, preamp: preamp)
        } catch {
            stop()
            throw error
        }
    }

    func update(gains: [Float], preamp: Float) {
        guard let equalizer, gains.count == Int(DD_EQ_BANDS) else { return }
        gains.withUnsafeBufferPointer { buffer in
            dd_eq_set_gains(equalizer, buffer.baseAddress, preamp)
        }
    }

    /// Safe to call more than once. Other apps' audio is unmuted as soon as the tap is gone.
    func stop() {
        if let ioProcID, aggregateID != AudioDevices.unknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        // Let a render already in flight finish before the equalizer is freed.
        renderQueue.sync {}
        if aggregateID != AudioDevices.unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDevices.unknown
        }
        if tapID != AudioDevices.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioDevices.unknown
        }
        if let equalizer {
            dd_eq_destroy(equalizer)
            self.equalizer = nil
        }
    }

    // MARK: - Private

    private func build(gains: [Float], preamp: Float) throws {
        guard let outputUID = AudioDevices.uid(of: outputDevice) else { throw EngineError.noOutputDevice }
        guard let ownProcess = AudioDevices.processObject(for: getpid()) else { throw EngineError.noProcessObject }

        // 1. A private stereo tap of every process except DevDock, muted at the source while
        //    tapped. Excluding DevDock matters: it plays the processed audio, and tapping that
        //    would feed the output back into itself.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "VYNL EQ"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioDevices.unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == 0 else { throw EngineError.createTap(status) }
        tapID = tap

        guard let format = AudioDevices.tapFormat(of: tap),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw EngineError.unsupportedFormat }

        // 2. A private aggregate device: the tap as its input, the real speakers as its output.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VYNL EQ",
            kAudioAggregateDeviceUIDKey: "com.spencermarchant.devdock.eq.\(UUID().uuidString)",
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
        guard status == 0 else { throw EngineError.createAggregate(status) }
        aggregateID = aggregate

        // 3. The equalizer, at the rate the aggregate device runs.
        sampleRate = AudioDevices.nominalSampleRate(of: aggregate)
            ?? AudioDevices.nominalSampleRate(of: outputDevice)
            ?? format.mSampleRate
        guard let dsp = dd_eq_create(sampleRate) else { throw EngineError.dsp }
        equalizer = dsp
        update(gains: gains, preamp: preamp)

        // 4. The render callback. The first start asks for System Audio Recording permission.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, renderQueue, Self.makeRenderBlock(dsp))
        guard status == 0, let procID else { throw EngineError.createIOProc(status) }
        ioProcID = procID

        status = AudioDeviceStart(aggregate, procID)
        guard status == 0 else { throw EngineError.start(status) }
    }

    /// Built in a static, nonisolated context so the block carries no actor isolation:
    /// it runs on the real-time audio queue and only calls into C.
    private static func makeRenderBlock(_ dsp: OpaquePointer) -> AudioDeviceIOBlock {
        return { _, inputData, _, outputData, _ in
            dd_eq_process(dsp, inputData, outputData)
        }
    }
}
