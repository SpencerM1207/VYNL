import AppKit
import Combine
import SwiftUI

/// "#8fdbc9", "8FDBC9" or "#8fd" → "#8FDBC9"; nil when it isn't a hex color.
enum HexColor {
    static func normalize(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + digits
    }

    static func components(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalize(text), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    static func color(_ text: String) -> Color? {
        components(text).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) }
    }

    static func nsColor(_ text: String) -> NSColor? {
        components(text).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
    }
}

/// Colors and font for every view, passed down through the SwiftUI environment so a change in
/// the Appearance tab restyles everything at once.
struct DevDockTheme {
    var accentHex: String
    var accent: Color
    var background: Color
    var text: Color
    /// "system", "rounded", "serif", "monospaced", or an installed font family name.
    var fontChoice: String

    static let standard = DevDockTheme(
        accentHex: AppearanceSettings.defaultAccent,
        backgroundHex: AppearanceSettings.defaultBackground,
        textHex: AppearanceSettings.defaultText,
        fontChoice: "system"
    )

    init(accentHex: String, backgroundHex: String, textHex: String, fontChoice: String) {
        self.accentHex = HexColor.normalize(accentHex) ?? AppearanceSettings.defaultAccent
        accent = HexColor.color(accentHex) ?? HexColor.color(AppearanceSettings.defaultAccent)!
        background = HexColor.color(backgroundHex) ?? HexColor.color(AppearanceSettings.defaultBackground)!
        text = HexColor.color(textHex) ?? .white
        self.fontChoice = fontChoice
    }

    var textPrimary: Color { text.opacity(0.92) }
    var textSecondary: Color { text.opacity(0.55) }

    var accentNS: NSColor {
        HexColor.nsColor(accentHex) ?? HexColor.nsColor(AppearanceSettings.defaultAccent)!
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch fontChoice {
        case "system": return .system(size: size, weight: weight)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        default: return Font.custom(fontChoice, size: size).weight(weight)
        }
    }

    /// For times and band labels. A chosen font family is used as is (Nerd Fonts are usually
    /// monospaced already); the built-in choices fall back to the system monospaced font.
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch fontChoice {
        case "system", "rounded", "serif", "monospaced":
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return Font.custom(fontChoice, size: size).weight(weight)
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: DevDockTheme { .standard }
}

extension EnvironmentValues {
    var theme: DevDockTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Wraps a panel's root view and keeps its theme in step with the settings.
struct ThemedRoot<Content: View>: View {
    @ObservedObject var appearance: AppearanceSettings
    let content: Content

    var body: some View {
        content.environment(\.theme, appearance.theme)
    }
}

/// A ready-made palette for the Appearance tab.
struct ThemePreset: Identifiable {
    let name: String
    let accent: String
    let background: String
    let text: String
    var id: String { name }

    static let all: [ThemePreset] = [
        ThemePreset(name: "Mint", accent: "#8FDBC9", background: "#090F11", text: "#FFFFFF"),
        ThemePreset(name: "Tokyo Night", accent: "#7AA2F7", background: "#1A1B26", text: "#C0CAF5"),
        ThemePreset(name: "Catppuccin", accent: "#CBA6F7", background: "#1E1E2E", text: "#CDD6F4"),
        ThemePreset(name: "Rosé Pine", accent: "#EBBCBA", background: "#191724", text: "#E0DEF4"),
        ThemePreset(name: "Gruvbox", accent: "#FABD2F", background: "#282828", text: "#EBDBB2"),
        ThemePreset(name: "Nord", accent: "#88C0D0", background: "#2E3440", text: "#ECEFF4"),
    ]
}

/// Everything in the Appearance tab, saved in UserDefaults. Main thread only.
final class AppearanceSettings: ObservableObject {
    static let defaultAccent = "#8FDBC9"
    static let defaultBackground = "#090F11"
    static let defaultText = "#FFFFFF"
    static let defaultBackgroundOpacity = 0.78

    /// No blur and no tint: the player floats straight over the wallpaper.
    @Published var clearBackground: Bool {
        didSet { save(clearBackground, Keys.clear) }
    }
    /// Strength of the background tint over the blur, 0...1.
    @Published var backgroundOpacity: Double {
        didSet { save(backgroundOpacity, Keys.backgroundOpacity) }
    }
    /// How solid the collapsed record looks, 0.2...1.
    @Published var recordOpacity: Double {
        didSet { save(recordOpacity, Keys.recordOpacity) }
    }
    @Published var fontChoice: String {
        didSet { save(fontChoice, Keys.font) }
    }
    @Published var accentHex: String {
        didSet { save(accentHex, Keys.accent) }
    }
    @Published var backgroundHex: String {
        didSet { save(backgroundHex, Keys.background) }
    }
    @Published var textHex: String {
        didSet { save(textHex, Keys.text) }
    }

    private enum Keys {
        static let clear = "appearance.clearBackground"
        static let backgroundOpacity = "appearance.backgroundOpacity"
        static let recordOpacity = "appearance.recordOpacity"
        static let font = "appearance.font"
        static let accent = "appearance.accent"
        static let background = "appearance.background"
        static let text = "appearance.text"
    }

    init() {
        let defaults = UserDefaults.standard
        clearBackground = defaults.bool(forKey: Keys.clear)
        backgroundOpacity = defaults.object(forKey: Keys.backgroundOpacity) as? Double ?? Self.defaultBackgroundOpacity
        recordOpacity = defaults.object(forKey: Keys.recordOpacity) as? Double ?? 1
        fontChoice = defaults.string(forKey: Keys.font) ?? "system"
        accentHex = defaults.string(forKey: Keys.accent).flatMap(HexColor.normalize) ?? Self.defaultAccent
        backgroundHex = defaults.string(forKey: Keys.background).flatMap(HexColor.normalize) ?? Self.defaultBackground
        textHex = defaults.string(forKey: Keys.text).flatMap(HexColor.normalize) ?? Self.defaultText
    }

    var theme: DevDockTheme {
        DevDockTheme(accentHex: accentHex, backgroundHex: backgroundHex, textHex: textHex, fontChoice: fontChoice)
    }

    func apply(_ preset: ThemePreset) {
        accentHex = preset.accent
        backgroundHex = preset.background
        textHex = preset.text
    }

    func restoreDefaults() {
        clearBackground = false
        backgroundOpacity = Self.defaultBackgroundOpacity
        recordOpacity = 1
        fontChoice = "system"
        apply(ThemePreset.all[0])
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
