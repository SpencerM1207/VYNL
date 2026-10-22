import Combine
import CoreAudio
import DevDockDSP
import Foundation

enum EQPreset: String, CaseIterable, Identifiable {
    case flat, bass, treble, vocal, pop, rock, jazz, classical, custom

    /// The eight buttons under the EQ. Custom is what you get after dragging a band.
    static let buttons: [EQPreset] = [.flat, .bass, .treble, .vocal, .pop, .rock, .jazz, .classical]

    var id: String { rawValue }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// dB for 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz. Custom is stored separately.
    var gains: [Float]? {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [6, 5, 4, 2, 0.5, 0, 0, 0, 0, 0]
        case .treble: return [0, 0, 0, 0, 0, 0.5, 2, 4, 5, 6]
        case .vocal: return [-3, -2, -1, 1, 3, 4, 3, 1, 0, -1]
        case .pop: return [-1, 0, 2, 3, 4, 3, 1, 0, 0, -1]
        case .rock: return [5, 4, 2, 0, -1, -1, 1, 3, 4, 5]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
        case .classical: return [4, 3, 2, 0, -1, -1, 0, 2, 3, 4]
        case .custom: return nil
        }
    }
}

/// EQ settings plus the audio engine's lifecycle. Main thread only.
final class EQController: ObservableObject {
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let maxGain: Float = 12

    @Published private(set) var gains: [Float]
    @Published private(set) var preset: EQPreset
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage: String?

    /// Set by PlayerStore. The watchdog only treats silence as a problem while music is
    /// supposed to be playing.
    var isMusicPlaying: () -> Bool = { false }

    private let output: OutputDeviceMonitor
    private var engine: ProcessTapEngine?
    private var watchdog: Timer?
    private var startedAt = Date()
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let preset = "eqPreset"
        static let customGains = "eqCustomGains"
        static let enabled = "eqEnabled"
        static let heardAudio = "eqHasHeardAudio"
    }

    init(output: OutputDeviceMonitor) {
        self.output = output
        let defaults = UserDefaults.standard
        let preset = EQPreset(rawValue: defaults.string(forKey: Keys.preset) ?? "") ?? .flat
        self.preset = preset
        self.gains = preset.gains ?? Self.savedCustomGains()
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    func start() {
        // Rebuild the engine on the new speakers when the default output changes.
        output.$deviceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.outputChanged() }
            .store(in: &cancellables)
        if isEnabled {
            startEngine()
        }
    }

    func shutdown() {
        stopEngine()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            startEngine()
        } else {
            stopEngine()
            statusMessage = nil
        }
    }

    func select(_ preset: EQPreset) {
        self.preset = preset
        gains = preset.gains ?? Self.savedCustomGains()
        UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset)
        pushGains()
    }

    func setGain(_ value: Float, at band: Int) {
        guard gains.indices.contains(band) else { return }
        let clamped = min(max(value, -Self.maxGain), Self.maxGain)
        guard clamped != gains[band] else { return }
        gains[band] = clamped
        if preset != .custom {
            preset = .custom
            UserDefaults.standard.set(EQPreset.custom.rawValue, forKey: Keys.preset)
        }
        UserDefaults.standard.set(gains.map { Double($0) }, forKey: Keys.customGains)
        pushGains()
    }

    func resetBand(_ band: Int) {
        setGain(0, at: band)
    }

    // MARK: - For the spectrum analyzer

    var sampleRate: Double? { engine?.sampleRate }

    /// Copies the newest processed samples. Returns how many were copied.
    func copyRecentSamples(into buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard let dsp = engine?.equalizer else { return 0 }
        return Int(dd_eq_copy_recent(dsp, buffer, Int32(count)))
    }

    // MARK: - Private

    /// Pull the level down by most of the biggest boost so loud tracks don't clip.
    /// The soft limiter in the DSP catches whatever is left.
    private var preamp: Float {
        -0.75 * max(gains.max() ?? 0, 0)
    }

    private func pushGains() {
        engine?.update(gains: gains, preamp: preamp)
    }

    private func startEngine() {
        stopEngine()
        guard let device = output.deviceID ?? AudioDevices.defaultOutputDevice() else {
            statusMessage = "No output device to play through."
            return
        }
        let engine = ProcessTapEngine(outputDevice: device)
        do {
            try engine.start(gains: gains, preamp: preamp)
            self.engine = engine
            isRunning = true
            statusMessage = nil
            startedAt = Date()
            startWatchdog()
        } catch {
            isRunning = false
            statusMessage = error.localizedDescription
            NSLog("VYNL: EQ failed to start: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        watchdog?.invalidate()
        watchdog = nil
        engine?.stop()
        engine = nil
        if isRunning {
            isRunning = false
        }
    }

    private func outputChanged() {
        guard isEnabled else { return }
        // Give macOS a moment to finish switching (Bluetooth can take a beat).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.startEngine()
        }
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkForSilence()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// If permission was denied, the tap delivers silence while still muting every app.
    /// Turn the EQ off rather than leave the Mac silent.
    private func checkForSilence() {
        guard let dsp = engine?.equalizer else { return }
        let defaults = UserDefaults.standard
        if dd_eq_has_heard_audio(dsp) != 0 {
            defaults.set(true, forKey: Keys.heardAudio)
        }
        // Before audio has ever come through, leave time to answer the permission prompt.
        let grace: TimeInterval = defaults.bool(forKey: Keys.heardAudio) ? 3 : 20
        guard Date().timeIntervalSince(startedAt) > grace,
              isMusicPlaying(),
              dd_eq_silent_seconds(dsp) > 3
        else { return }

        stopEngine()
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        statusMessage = "No sound reached the EQ, so it turned itself off. Allow VYNL in System Settings > Privacy & Security > Screen & System Audio Recording, then turn the EQ on again."
    }

    private static func savedCustomGains() -> [Float] {
        let saved = (UserDefaults.standard.array(forKey: Keys.customGains) as? [Double])?.map { Float($0) } ?? []
        return saved.count == labels.count ? saved : Array(repeating: 0, count: labels.count)
    }
}
