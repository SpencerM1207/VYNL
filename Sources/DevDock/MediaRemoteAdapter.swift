import AppKit

/// Runs ungive/mediaremote-adapter (BSD-3) through /usr/bin/perl. Since macOS 15.4, apps can't
/// read Now Playing directly, but the system perl still can. The adapter prints one JSON object
/// per line: {"type":"data","diff":Bool,"payload":{...}}. A diff payload holds only changed
/// keys, with null meaning "removed". Main thread only, except the pipe reader.
final class MediaRemoteAdapter {
    /// IDs for the adapter's `send` command.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    var onUpdate: ((NowPlayingInfo?) -> Void)?
    /// Called when the adapter can't run, so the service can fall back to Spotify.
    var onFailure: (() -> Void)?

    private let scriptURL: URL?
    private let frameworkURL: URL?
    private var process: Process?
    private var oneShots = Set<Process>()
    private var state: [String: Any] = [:]
    private var artwork: NSImage?
    private var artworkKey = 0
    private var quickFailures = 0
    private var stopped = true

    init() {
        let found = Self.locate()
        scriptURL = found?.script
        frameworkURL = found?.framework
    }

    var isInstalled: Bool {
        scriptURL != nil && frameworkURL != nil
    }

    func start() {
        stopped = false
        launchStream()
    }

    func stop() {
        stopped = true
        if let process {
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        process = nil
    }

    func send(_ command: Command) {
        runOnce(["send", String(command.rawValue)])
    }

    func seek(to seconds: TimeInterval) {
        let micros = Int64(max(seconds, 0) * 1_000_000)
        runOnce(["seek", String(micros)])
    }

    // MARK: - Stream

    private func launchStream() {
        guard let scriptURL, let frameworkURL, !stopped, process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // --micros gives durationMicros, elapsedTimeMicros and timestampEpochMicros.
        process.arguments = [scriptURL.path, frameworkURL.path, "stream", "--micros", "--debounce=50"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let reader = LineReader()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in reader.append(data) {
                // Parse (and decode artwork) off the main thread.
                guard let message = Self.parse(line) else { continue }
                DispatchQueue.main.async { [weak self] in
                    self?.apply(message)
                }
            }
        }

        let launchedAt = Date()
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                self?.streamEnded(status: status, runningFor: Date().timeIntervalSince(launchedAt))
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("VYNL: couldn't launch mediaremote-adapter: \(error.localizedDescription)")
            onFailure?()
        }
    }

    private func streamEnded(status: Int32, runningFor seconds: TimeInterval) {
        process = nil
        guard !stopped else { return }
        quickFailures = seconds < 5 ? quickFailures + 1 : 0
        if quickFailures >= 3 {
            NSLog("VYNL: mediaremote-adapter keeps exiting (status \(status)).")
            onFailure?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.launchStream()
        }
    }

    private func apply(_ message: Message) {
        guard !stopped else { return }
        if let payload = message.payload {
            if message.isDiff {
                for (key, value) in payload {
                    if value is NSNull {
                        state.removeValue(forKey: key)
                    } else {
                        state[key] = value
                    }
                }
            } else {
                state = payload
            }
        } else {
            state = [:]
        }

        switch message.artwork {
        case .unchanged:
            break
        case .cleared:
            if artwork != nil {
                artwork = nil
                artworkKey += 1
            }
        case .image(let image):
            artwork = image
            artworkKey += 1
        }

        onUpdate?(Self.makeInfo(from: state, artwork: artwork, artworkKey: artworkKey))
    }

    // MARK: - One-shot commands

    private func runOnce(_ arguments: [String]) {
        guard let scriptURL, let frameworkURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.oneShots.remove(finished)
            }
        }
        do {
            try process.run()
            oneShots.insert(process)
        } catch {
            NSLog("VYNL: adapter command \(arguments) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private enum ArtworkChange {
        case unchanged, cleared, image(NSImage)
    }

    private struct Message {
        var isDiff: Bool
        /// nil means nothing is playing.
        var payload: [String: Any]?
        var artwork: ArtworkChange
    }

    private static func parse(_ line: Data) -> Message? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (object["type"] as? String) == "data"
        else { return nil }

        let isDiff = (object["diff"] as? Bool) ?? false
        guard var payload = object["payload"] as? [String: Any] else {
            return Message(isDiff: false, payload: nil, artwork: .cleared)
        }

        var artwork = ArtworkChange.unchanged
        if let base64 = payload["artworkData"] as? String {
            if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               let image = NSImage(data: data) {
                artwork = .image(image)
            }
        } else if payload["artworkData"] is NSNull || !isDiff {
            artwork = .cleared
        }
        payload.removeValue(forKey: "artworkData")
        return Message(isDiff: isDiff, payload: payload, artwork: artwork)
    }

    private static func makeInfo(from state: [String: Any], artwork: NSImage?, artworkKey: Int) -> NowPlayingInfo? {
        guard let title = state["title"] as? String, !title.isEmpty else { return nil }

        func number(_ key: String) -> Double? {
            (state[key] as? NSNumber)?.doubleValue
        }

        // Browsers report a helper process; the parent is the browser itself.
        let bundleID = (state["parentApplicationBundleIdentifier"] as? String)
            ?? (state["bundleIdentifier"] as? String)
            ?? ""
        let duration = number("durationMicros").map { $0 / 1_000_000 } ?? number("duration") ?? 0
        let elapsed = number("elapsedTimeMicros").map { $0 / 1_000_000 } ?? number("elapsedTime") ?? 0
        let elapsedAt = number("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        let rate = number("playbackRate") ?? 1
        let playing = (state["playing"] as? Bool) ?? (rate > 0)

        return NowPlayingInfo(
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: duration,
            elapsed: elapsed,
            elapsedAt: elapsedAt,
            playbackRate: rate,
            isPlaying: playing,
            sourceBundleID: bundleID,
            artwork: artwork,
            artworkKey: artworkKey
        )
    }

    // MARK: - Finding the adapter

    /// The bundled app keeps the script in Resources and the framework in Frameworks
    /// (scripts/bundle.sh). `swift run` finds them in Vendor/MediaRemoteAdapter instead.
    private static func locate() -> (script: URL, framework: URL)? {
        var pairs: [(URL, URL)] = []
        if let resources = Bundle.main.resourceURL, let frameworks = Bundle.main.privateFrameworksURL {
            pairs.append((
                resources.appendingPathComponent("mediaremote-adapter.pl"),
                frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
            ))
        }
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            let vendor = current.appendingPathComponent("Vendor/MediaRemoteAdapter")
            pairs.append((
                vendor.appendingPathComponent("mediaremote-adapter.pl"),
                vendor.appendingPathComponent("MediaRemoteAdapter.framework")
            ))
            directory = current.deletingLastPathComponent()
        }
        let fileManager = FileManager.default
        for (script, framework) in pairs
            where fileManager.fileExists(atPath: script.path) && fileManager.fileExists(atPath: framework.path) {
            return (script, framework)
        }
        return nil
    }
}

/// Splits a byte stream into newline-terminated lines. Used by one reader at a time.
private final class LineReader {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
