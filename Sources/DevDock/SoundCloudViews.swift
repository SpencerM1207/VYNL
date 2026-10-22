import AppKit
import SwiftUI

/// The SoundCloud tab: DevDock's own search when API keys are set, SoundCloud's site otherwise.
struct SoundCloudPane: View {
    @ObservedObject var service: SoundCloudService
    let player: SoundCloudPlayer
    let webSession: SoundCloudWebSession

    @State private var editingKeys = false

    var body: some View {
        Group {
            if editingKeys {
                SoundCloudKeysForm(service: service) { editingKeys = false }
            } else if service.hasCredentials {
                SoundCloudSearchView(service: service, player: player) { editingKeys = true }
            } else {
                SoundCloudWebPane(session: webSession) { editingKeys = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Native search

struct SoundCloudSearchView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var service: SoundCloudService
    @ObservedObject var player: SoundCloudPlayer
    let onEditKeys: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let error = player.errorMessage {
                Text(error)
                    .font(theme.font(10))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if player.currentTrackID != nil {
                // SoundCloud's own mini player: the official way to embed playback.
                HostedWebView(webView: player.webView)
                    .frame(height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            HStack {
                Text("Powered by SoundCloud")
                Spacer()
                Button("API keys", action: onEditKeys)
                    .buttonStyle(.plain)
            }
            .font(theme.font(9, .medium))
            .foregroundStyle(theme.textSecondary)
        }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(11, .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("Search SoundCloud", text: $service.query)
                .textFieldStyle(.plain)
                .font(theme.font(12))
                .foregroundStyle(theme.textPrimary)
                .focused($searchFocused)
                .onSubmit { service.search() }
            if service.state == .searching {
                ProgressView()
                    .controlSize(.small)
            } else if !service.query.isEmpty {
                Button {
                    service.query = ""
                    service.clearResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? theme.accent.opacity(0.5) : Color.white.opacity(0.08))
        )
    }

    @ViewBuilder
    private var results: some View {
        switch service.state {
        case .idle:
            hint("Search for a song, artist or mix, then press Return.")
        case .searching where service.results.isEmpty:
            hint("Searching…")
        case .failed(let message):
            Text(message)
                .font(theme.font(11))
                .foregroundStyle(Color.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        default:
            if service.results.isEmpty {
                hint("No results.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(service.results) { track in
                            SoundCloudRow(
                                track: track,
                                isCurrent: player.currentTrackID == track.id,
                                isPlaying: player.isPlaying && player.currentTrackID == track.id
                            ) {
                                player.play(track, from: service.results)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(theme.font(11))
            .foregroundStyle(theme.textSecondary)
            .padding(.top, 6)
    }
}

/// One search result. Clicking it plays the track; the list becomes the queue.
struct SoundCloudRow: View {
    @Environment(\.theme) private var theme
    let track: SoundCloudTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncImage(url: track.artworkURL(size: "t67x67")) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(theme.font(11))
                                    .foregroundStyle(theme.textSecondary)
                            )
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(theme.font(12, .semibold))
                        .foregroundStyle(isCurrent ? theme.accent : theme.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(theme.font(10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if track.isPreview {
                    Text("PREVIEW")
                        .font(theme.font(8, .bold))
                        .tracking(0.6)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                        .help("SoundCloud only allows a short preview of this track here")
                }
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(theme.font(11, .semibold))
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative)
                }
                Text(formatTime(track.durationSeconds))
                    .font(theme.mono(10, .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isCurrent ? theme.accent.opacity(0.12) : Color.white.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - API keys

struct SoundCloudKeysForm: View {
    @Environment(\.theme) private var theme
    @ObservedObject var service: SoundCloudService
    let onDone: () -> Void

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isChecking = false
    @State private var errorMessage: String?

    private static let registerURL = URL(string: "https://developers.soundcloud.com/docs/api/register-app")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SoundCloud API keys")
                .font(theme.font(13, .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("SoundCloud gives API keys to Artist Pro accounts. Register an app on SoundCloud's developer page, then paste its Client ID and Client Secret here. They're saved only on this Mac, in a file only your user account can read.")
                .font(theme.font(11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open SoundCloud's developer page") {
                NSWorkspace.shared.open(Self.registerURL)
            }
            .buttonStyle(.link)
            .font(theme.font(11))

            labeledField("Client ID") {
                TextField("", text: $clientID)
            }
            labeledField("Client Secret") {
                SecureField("", text: $clientSecret)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(theme.font(10))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if service.hasCredentials {
                    Button("Remove keys") {
                        service.removeCredentials()
                        onDone()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.orange.opacity(0.9))
                }
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                Button(action: save) {
                    Text(isChecking ? "Checking…" : "Save")
                        .font(theme.font(11, .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(isChecking || clientID.isEmpty || clientSecret.isEmpty)
                .opacity(clientID.isEmpty || clientSecret.isEmpty ? 0.5 : 1)
            }
            .font(theme.font(11, .medium))

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func labeledField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(theme.font(10, .medium))
                .foregroundStyle(theme.textSecondary)
            field()
                .textFieldStyle(.plain)
                .font(theme.mono(12))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                )
        }
    }

    private func save() {
        isChecking = true
        errorMessage = nil
        Task {
            let error = await service.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            isChecking = false
            if let error {
                errorMessage = error
            } else {
                onDone()
            }
        }
    }
}

// MARK: - Embedded site

/// soundcloud.com inside the panel, with simple navigation and a way to add API keys.
struct SoundCloudWebPane: View {
    @Environment(\.theme) private var theme
    let session: SoundCloudWebSession
    let onAddKeys: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                navButton("chevron.left", help: "Back") { session.goBack() }
                navButton("chevron.right", help: "Forward") { session.goForward() }
                navButton("arrow.clockwise", help: "Reload") { session.reload() }
                navButton("house", help: "SoundCloud home") { session.goHome() }
                Text("soundcloud.com")
                    .font(theme.font(10, .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button(action: onAddKeys) {
                    Label("Add API keys for VYNL search", systemImage: "key.fill")
                }
                .buttonStyle(.plain)
                .font(theme.font(10, .semibold))
                .foregroundStyle(theme.accent)
                .help("SoundCloud API keys (Artist Pro) switch this tab to VYNL's own search")
            }
            HostedWebView(webView: session.webView)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                )
        }
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.font(11, .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary)
        .help(help)
    }
}
