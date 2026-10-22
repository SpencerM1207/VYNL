# VYNL

A music widget for macOS: a small spinning record on your desktop that expands into a player with synced lyrics and a real, system-wide 10-band EQ. It works with Spotify, SoundCloud, Apple Music, YouTube, or anything else that shows up in macOS Now Playing.

VYNL used to be called DevDock, which is still the name of this project folder. The plan lives in the "DevDock Music Widget: macOS Plan" doc. `handoff.md` has the current status and notes for whoever works on it next.

## Build and run

Runs on macOS 14.2 or later, on Apple Silicon or Intel (writing down lyrics for songs LRCLIB doesn't have needs macOS 26). Building needs **Xcode 26 or newer**: older versions don't know the speech APIs.

1. Install Xcode from the App Store and open it once so it finishes installing its components.
2. Install [Homebrew](https://brew.sh) if you don't have it, then cmake, for the Now Playing helper: `brew install cmake`
3. In Terminal, go to this folder and build. It downloads and builds the Now Playing helper the first time, builds VYNL, and installs it to `~/Applications/VYNL.app`. The output is saved to `logs/build.log`.
   ```
   cd path/to/this/folder
   scripts/build-and-log.sh
   ```
4. Run it: `open ~/Applications/VYNL.app`. The record appears at the top left of your screen.

If Terminal says "permission denied", run `chmod +x scripts/*.sh` and try again. To update later, replace the folder (or `git pull`) and run step 3 again.

Other ways to build: `scripts/bundle.sh` (app only), `scripts/fetch-adapter.sh` (Now Playing helper only), or open `Package.swift` in Xcode. Use the bundled app for real testing. Permission prompts only work properly for a `.app`, not `swift run`.

The app icon is `Resources/AppIcon.icns`, made by `Design/make_icon.py` (change the two gradient colors at the top to recolor it).

## Using it

- **Open the player:** click the record, press Control-Option-M, or use the record icon in the menu bar.
- **Move the record:** drag it anywhere. It snaps to nearby edges and remembers the spot.
- **Close it:** click the top bar or the chevron, press Esc or Control-Option-M, or click another app. The pin keeps it open when you click elsewhere.
- **Lyrics:** shown beside Now Playing. The mic button or Settings turns them on and off; Settings also picks the side.
- **Settings:** the sliders icon. Lyrics, clear background, opacity, font, and colors.
- **Seek:** drag the progress bar, or click a lyric line. **EQ band:** drag a knob, double-click to reset it to 0 dB.
- **Menu:** right-click the record, or click the menu bar icon. Quit is there.

## Permissions (asked once)

- **System Audio Recording:** asked the first time you turn on the EQ. While the EQ is on, every app's sound goes through VYNL. If no sound comes through, the EQ turns itself off after a few seconds so your Mac is never left silent. Re-allow it under System Settings > Privacy & Security > Screen & System Audio Recording.
- **Automation (Spotify):** only asked if the Now Playing helper is missing and VYNL falls back to controlling Spotify directly.

Turning the EQ off, or quitting VYNL, puts audio back to normal immediately.

## Tweaks

Run these in Terminal, then quit and reopen VYNL:

```
defaults write com.spencermarchant.vynl topOffset -float 8   # move the record lower, e.g. under SketchyBar
defaults write com.spencermarchant.vynl side right           # top right instead of top left
```

## Credits

Now Playing access uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg (BSD-3-Clause), downloaded by `scripts/fetch-adapter.sh`. Lyrics come from [LRCLIB](https://lrclib.net), a free, open lyrics database.
