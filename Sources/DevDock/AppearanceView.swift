import AppKit
import SwiftUI

/// The Settings tab: lyrics, clear background, opacity, font, hex colors and palettes.
/// Every change applies live and is saved.
struct AppearanceView: View {
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var dock: DockModel
    @Environment(\.theme) private var theme

    /// Installed font families, read once.
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Lyrics") {
                    row("Show") {
                        Toggle("Show lyrics", isOn: $dock.showsLyrics)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .tint(theme.accent)
                            .help("Synced lyrics beside Now Playing")
                        Spacer()
                    }
                    Group {
                        row("Side") {
                            Picker("Side", selection: $dock.lyricsSide) {
                                Text("Left").tag(LyricsSide.left)
                                Text("Right").tag(LyricsSide.right)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                            Spacer()
                        }
                        row("Transcribe") {
                            Toggle("Transcribe missing lyrics", isOn: $dock.transcribesLyrics)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .tint(theme.accent)
                            Spacer()
                        }
                        Text("For songs LRCLIB doesn't have, VYNL writes down what it hears, on this Mac. Expect mistakes.")
                            .font(theme.font(10))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 78)
                    }
                    .disabled(!dock.showsLyrics)
                    .opacity(dock.showsLyrics ? 1 : 0.4)
                }

                section("Background") {
                    row("Clear") {
                        Toggle("Clear background", isOn: $appearance.clearBackground)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .tint(theme.accent)
                            .help("No blur and no tint: the player floats over your wallpaper")
                        Spacer()
                    }
                    row("Opacity") {
                        percentSlider($appearance.backgroundOpacity, range: 0...1)
                    }
                    .disabled(appearance.clearBackground)
                    .opacity(appearance.clearBackground ? 0.4 : 1)
                    row("Record") {
                        percentSlider($appearance.recordOpacity, range: 0.2...1)
                    }
                }

                section("Font") {
                    row("Family") {
                        Picker("Font", selection: $appearance.fontChoice) {
                            Text("System").tag("system")
                            Text("Rounded").tag("rounded")
                            Text("Serif").tag("serif")
                            Text("Monospaced").tag("monospaced")
                            Divider()
                            ForEach(Self.fontFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                        Spacer()
                    }
                    Text("The quick brown fox · 03:28")
                        .font(theme.font(12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.leading, 78)
                }

                section("Colors") {
                    HexColorField(label: "Accent", hex: $appearance.accentHex)
                    HexColorField(label: "Background", hex: $appearance.backgroundHex)
                    HexColorField(label: "Text", hex: $appearance.textHex)
                    presetRow
                }

                HStack {
                    Spacer()
                    Button("Restore defaults") {
                        appearance.restoreDefaults()
                    }
                    .buttonStyle(.plain)
                    .font(theme.font(10, .semibold))
                    .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Palettes")
                .font(theme.font(10, .medium))
                .foregroundStyle(theme.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(ThemePreset.all) { preset in
                    let selected = HexColor.normalize(appearance.accentHex) == preset.accent
                        && HexColor.normalize(appearance.backgroundHex) == preset.background
                    Button {
                        appearance.apply(preset)
                    } label: {
                        HStack(spacing: 6) {
                            HStack(spacing: 0) {
                                swatch(preset.background)
                                swatch(preset.accent)
                                swatch(preset.text)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            Text(preset.name)
                                .font(theme.font(10, .medium))
                                .lineLimit(1)
                                .foregroundStyle(selected ? theme.accent : theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? theme.accent.opacity(0.12) : Color.white.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        Rectangle()
            .fill(HexColor.color(hex) ?? .clear)
            .frame(width: 8, height: 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(theme.font(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(theme.textSecondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(theme.font(11, .medium))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 68, alignment: .leading)
            content()
        }
        .frame(minHeight: 22)
    }

    private func percentSlider(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(theme.accent)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(theme.mono(10, .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// A hex color field with a live swatch. Valid colors apply as you type; anything else is
/// marked and ignored until it becomes valid.
struct HexColorField: View {
    let label: String
    @Binding var hex: String

    @Environment(\.theme) private var theme
    @State private var draft = ""

    var body: some View {
        let valid = HexColor.normalize(draft) != nil
        HStack(spacing: 10) {
            Text(label)
                .font(theme.font(11, .medium))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 68, alignment: .leading)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HexColor.color(draft) ?? HexColor.color(hex) ?? .clear)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2))
                )
            TextField("#RRGGBB", text: $draft)
                .textFieldStyle(.plain)
                .font(theme.mono(12))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 8)
                .frame(width: 110, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(valid ? Color.white.opacity(0.08) : Color.orange.opacity(0.7))
                )
                .onSubmit {
                    draft = HexColor.normalize(draft) ?? hex
                }
            Spacer()
        }
        .onAppear { draft = hex }
        .onChange(of: draft) { _, newValue in
            if let normalized = HexColor.normalize(newValue), normalized != hex {
                hex = normalized
            }
        }
        .onChange(of: hex) { _, newValue in
            // A palette or Restore defaults changed it from outside.
            if HexColor.normalize(draft) != newValue {
                draft = newValue
            }
        }
    }
}
