import Combine
import CoreAudio
import Foundation

/// Small wrappers around the Core Audio HAL property API.
enum AudioDevices {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return status == 0 && device != unknown ? device : nil
    }

    static func name(of object: AudioObjectID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: object)
    }

    static func uid(of device: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: device)
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == 0 && rate > 0 ? rate : nil
    }

    /// The HAL's object for a process, needed to exclude DevDock from its own tap.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == 0 && object != unknown ? object : nil
    }

    static func tapFormat(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        return status == 0 ? format : nil
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Publishes the current default output device ("JBL Tune 720BT", "MacBook Air Speakers").
/// Main thread only.
final class OutputDeviceMonitor: ObservableObject {
    @Published private(set) var deviceID: AudioDeviceID?
    @Published private(set) var deviceName = ""

    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        refresh()
        guard listener == nil else { return }
        var address = AudioDevices.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioDevices.system, &address, DispatchQueue.main, block)
        if status == 0 {
            listener = block
        }
    }

    private func refresh() {
        let id = AudioDevices.defaultOutputDevice()
        let name = id.flatMap { AudioDevices.name(of: $0) } ?? "No output"
        if name != deviceName {
            deviceName = name
        }
        if id != deviceID {
            deviceID = id
        }
    }
}
