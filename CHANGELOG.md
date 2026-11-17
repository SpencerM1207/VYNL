# Changelog

## 0.6.1 (Nov 17, 2026)

### Fixed
- **Player hidden on some desktops:** 0.6.0's fix didn't hold, and the player could still open invisibly on every desktop but one. The player now moves to the desktop you're on each time it opens, and a pinned player follows you when you switch desktops.

## 0.6.0 (Nov 17, 2026)

### New
- **Open at login:** Settings > General > Login starts VYNL when you log in.
- **Sound output switch:** click the speaker tag under the song title to pick speakers, headphones or any other output.
- **EQ per output:** each output remembers its own preset and custom curve, and the EQ switches automatically when the output changes.
- **Eyedropper:** a button next to each color in Settings picks a color from anywhere on screen, so you can match your wallpaper without knowing its hex code.
- **Scrolling titles:** long song titles scroll sideways while playing instead of being cut off.

### Changed
- **Close by clicking outside:** clicking empty desktop now closes the player, the same as clicking another app. The pin still keeps it open.
- **Settings icon:** now a small gear instead of sliders.
- **Easy install:** a ready-made app for Apple Silicon Macs is attached to each release and kept in `dist/VYNL.zip`, so friends don't need Xcode.

### Fixed
- **Player missing on one desktop:** on some desktops, clicking the record hid the record without showing the player. It now always opens on the desktop you're on.
- **EQ turning off between songs:** silence at the end of a song no longer switches the EQ off. The safety check now only runs until the EQ first hears sound.
- **Permission prompts after updates:** builds signed with a developer certificate keep their System Audio Recording and Automation permissions across updates.

## 0.5.0 (Oct 22, 2026)

- Music tab with Spotify, SoundCloud and Apple Music.
- Follow one app from the source tag or Settings.
- Lyrics transcription for songs LRCLIB doesn't have (macOS 26).
- Lyrics timing fixes for extended and remixed versions, with tap-to-sync and nudges.
