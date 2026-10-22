import AVFoundation
import Foundation
import Speech

/// What a transcription session reports back.
enum TranscriptionEvent {
    case preparing(String)
    case listening
    /// A finished line.
    case final(String)
    /// The line being heard right now; it may still change.
    case partial(String)
    /// Nothing audible arrived for a while: most likely no System Audio Recording permission.
    case noAudio
    case failed(String)
}

/// For songs LRCLIB doesn't have: writes down what it hears, on this Mac, as live captions in
/// the lyrics column. Uses macOS 26's SpeechAnalyzer fed by an unmuted system audio tap.
/// Sung words over a beat are hard to recognize, so the column warns to expect mistakes.
/// Runs only while asked to (the lyrics column is visible and the song isn't on LRCLIB);
/// lines are kept per song for this run, so reopening the player shows them again.
@MainActor
final class LyricsTranscriber: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(String)
        case listening
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [String] = []
    @Published private(set) var partial = ""
    @Published private(set) var hearsAudio = true

    private static let keptSongs = 20

    private var songID: String?
    /// A TranscriptionSession on macOS 26 and later.
    private var session: AnyObject?
    private var saved: [String: [String]] = [:]
    private var savedOrder: [String] = []

    func start(songID: String) {
        if self.songID == songID, session != nil {
            return
        }
        stop()
        self.songID = songID
        lines = saved[songID] ?? []
        partial = ""
        hearsAudio = true
        guard #available(macOS 26.0, *) else {
            state = .unavailable("Writing down lyrics needs macOS 26 or later.")
            return
        }
        state = .preparing("Getting ready to listen…")
        let session = TranscriptionSession { [weak self] event in
            self?.handle(event, for: songID)
        }
        self.session = session
        session.start()
    }

    func stop() {
        if let songID {
            remember(lines, for: songID)
        }
        if #available(macOS 26.0, *), let session = session as? TranscriptionSession {
            session.stop()
        }
        session = nil
        songID = nil
        partial = ""
        if state != .idle {
            state = .idle
        }
    }

    // MARK: - Private

    private func handle(_ event: TranscriptionEvent, for id: String) {
        guard id == songID else { return }
        switch event {
        case .preparing(let message):
            state = .preparing(message)
        case .listening:
            state = .listening
        case .partial(let text):
            partial = text
        case .final(let text):
            if !text.isEmpty {
                lines.append(text)
                remember(lines, for: id)
            }
            partial = ""
        case .noAudio:
            hearsAudio = false
        case .failed(let message):
            if #available(macOS 26.0, *), let session = session as? TranscriptionSession {
                session.stop()
            }
            session = nil
            partial = ""
            state = .unavailable(message)
        }
    }

    private func remember(_ lines: [String], for id: String) {
        guard !lines.isEmpty else { return }
        if saved[id] == nil {
            savedOrder.append(id)
            if savedOrder.count > Self.keptSongs {
                saved[savedOrder.removeFirst()] = nil
            }
        }
        saved[id] = lines
    }
}

/// One listening session: speech model assets, the analyzer, the audio tap and the pump that
/// feeds one into the other. Stop it to tear everything down; it reports nothing afterwards.
@available(macOS 26.0, *)
@MainActor
final class TranscriptionSession {
    private let onEvent: (TranscriptionEvent) -> Void
    private var capture: SystemAudioCapture?
    private var pump: AudioPump?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var runTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var isStopped = false

    init(onEvent: @escaping (TranscriptionEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        runTask?.cancel()
        resultsTask?.cancel()
        pump?.stop()
        pump = nil
        capture?.stop()
        capture = nil
        inputBuilder?.finish()
        inputBuilder = nil
        if let analyzer {
            Task {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }
        analyzer = nil
    }

    // MARK: - Private

    private func run() async {
        do {
            await Self.requestSpeechPermissionIfNeeded()
            guard !isStopped else { return }
            guard let locale = await Self.transcriptionLocale() else {
                emit(.failed("Writing down lyrics doesn't support this Mac's language yet."))
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                emit(.preparing("Downloading the speech model (one time)…"))
                try await request.downloadAndInstall()
            }
            guard !isStopped else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                emit(.failed("The speech model isn't ready yet. Try again in a minute."))
                return
            }

            let (sequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            inputBuilder = builder
            try await analyzer.start(inputSequence: sequence)
            guard !isStopped else { return }

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.emit(result.isFinal ? .final(text) : .partial(text))
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.emit(.failed(error.localizedDescription))
                    }
                }
            }

            let capture = SystemAudioCapture()
            try capture.start()
            self.capture = capture
            let pump = try AudioPump(capture: capture, outputFormat: format, input: builder) { [weak self] in
                Task { @MainActor in
                    self?.emit(.noAudio)
                }
            }
            pump.start()
            self.pump = pump
            emit(.listening)
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private func emit(_ event: TranscriptionEvent) {
        guard !isStopped else { return }
        onEvent(event)
    }

    /// The Mac's language if the speech model supports it, else US English.
    private static func transcriptionLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        return supported.first { $0.identifier(.bcp47) == current.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == current.language.languageCode }
            ?? supported.first { $0.identifier(.bcp47) == "en-US" }
    }

    /// Asks once, the first time. Transcription carries on whatever the answer; if macOS needs
    /// the permission, the analyzer reports the error.
    private static func requestSpeechPermissionIfNeeded() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Every 100 ms, drains the capture ring, converts the audio to the speech model's format and
/// hands it to the analyzer. Runs on its own queue.
@available(macOS 26.0, *)
final class AudioPump: @unchecked Sendable {
    enum PumpError: LocalizedError {
        case format

        var errorDescription: String? {
            "Couldn't convert the Mac's audio for the speech model."
        }
    }

    /// 8 s without sound while listening most likely means no permission.
    private static let silenceTicks = 80

    private let capture: SystemAudioCapture
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onSilence: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.spencermarchant.vynl.transcribe", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var reportedSilence = false

    init(
        capture: SystemAudioCapture,
        outputFormat: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        onSilence: @escaping @Sendable () -> Void
    ) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: capture.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw PumpError.format }
        self.capture = capture
        self.input = input
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.onSilence = onSilence
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        queue.sync {
            self.timer = timer
        }
        timer.resume()
    }

    /// Returns once no tick is running, so the capture can be stopped right after.
    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        ticks += 1
        if !reportedSilence, ticks >= Self.silenceTicks, !capture.hasHeardAudio {
            reportedSilence = true
            onSilence()
        }
        let samples = capture.read(maxCount: Int(capture.sampleRate))
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        if let converted = convert(buffer) {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Streams through one converter, so resampling carries over between chunks.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let feed = OneBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let next = feed.take() {
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Hands a buffer to AVAudioConverter exactly once.
private final class OneBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
