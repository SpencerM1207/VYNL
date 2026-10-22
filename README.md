# VYNL

A music widget for macOS: a small spinning record on your desktop that expands into a player with synced lyrics and a real, system-wide 10-band EQ. It works with Spotify, SoundCloud, Apple Music, YouTube, or anything else that shows up in macOS Now Playing.

## Install it on your Mac

You build VYNL yourself from this code. It takes about 15 minutes the first time, most of it downloading Xcode. Because the app is built on your own Mac, macOS opens it without any security warning.

**You need:** a Mac with macOS 14.2 or later (Apple Silicon or Intel) and about 15 GB free for Xcode. Writing down lyrics for songs that aren't in the lyrics database needs macOS 26.

### 1. Install Xcode

Get **Xcode** from the Mac App Store (it must be version 26 or newer). If the App Store says it needs a newer macOS, update first in System Settings > General > Software Update.

Open Xcode once, agree to the license, and let it finish installing its components. You can quit it after that; you won't use it directly.

### 2. Open Terminal

Press Command-Space, type **Terminal**, and press Return. Every command below is pasted into this window, followed by Return.

### 3. Install Homebrew and two tools

Homebrew installs command-line tools. Skip this line if you already have it:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It asks for your Mac password (nothing shows as you type; that's normal). When it finishes, it prints **Next steps** with two or three commands: run those too.

Then install cmake (builds the Now Playing helper) and GitHub's tool (downloads this code):

```
brew install cmake gh
```

### 4. Sign in to GitHub (private repo only)

If this repo is private, you need a GitHub account and an invite: accept it from the email or at github.com/notifications. Then:

```
gh auth login
```

Choose **GitHub.com**, then **HTTPS**, then **Login with a web browser**. Terminal shows a code like `ABCD-1234`; press Return, paste the code into the page that opens, and click **Authorize**.

If the repo is public, skip this step.

### 5. Download VYNL

```
cd ~/Documents
gh repo clone SpencerM1207/VYNL
```

This makes a **VYNL** folder in Documents.

### 6. Build it

```
cd ~/Documents/VYNL
scripts/build-and-log.sh
```

The first build downloads and builds the Now Playing helper, so give it a few minutes. It's done when it says **installed it to ~/Applications/VYNL.app**.

### 7. Open it

```
open ~/Applications/VYNL.app
```

A small spinning record appears at the top left of your screen and a record icon in the menu bar. Click the record (or press Control-Option-M) to open the player. To start it automatically, add VYNL in System Settings > General > Login Items.

### Updating

```
cd ~/Documents/VYNL
git pull
scripts/build-and-log.sh
```

### If something goes wrong

- **"permission denied"** when building: run `chmod +x scripts/*.sh` and build again.
- **Errors mentioning xcrun, the SDK, or developer tools:** make sure Xcode 26 or newer is installed and has been opened once, then build again.
- **"command not found: brew"**: run the **Next steps** commands Homebrew printed in step 3, or close Terminal, open a new window, and try again.
- **Anything else:** the full output is saved in `logs/build.log` in the VYNL folder.

## Using it

- **Open the player:** click the record, press Control-Option-M, or use the record icon in the menu bar.
- **Move the record:** drag it anywhere. It snaps to nearby edges and remembers the spot.
- **Close it:** click the top bar or the chevron, press Esc or Control-Option-M, or click another app. The pin keeps it open when you click elsewhere.
- **Lyrics:** shown beside Now Playing. The mic button or Settings turns them on and off; Settings also picks the side. The timer button fixes the timing: tap the line you're hearing, or nudge earlier/later.
- **Music tab:** pick Spotify, SoundCloud or Apple Music at the top. Spotify and SoundCloud open their websites right in the player (sign in once). Apple Music searches your library and the Apple Music catalog: library songs play in the Music app, catalog songs open there.
- **Follow one app:** click the source tag under the song title (or Settings > Now Playing > Follow) and pick Spotify, SoundCloud or Apple Music. The player, controls and lyrics then stay on that app even if something else is playing. Auto shows whatever's playing.
- **Settings:** the sliders icon. Which app to follow, lyrics, clear background, opacity, font, and colors.
- **Seek:** drag the progress bar, or click a lyric line. **EQ band:** drag a knob, double-click to reset it to 0 dB.
- **Menu:** right-click the record, or click the menu bar icon. Quit is there.

## Permissions (asked once)

- **System Audio Recording:** asked the first time you turn on the EQ, or when VYNL listens to a song to write down its lyrics. While the EQ is on, every app's sound goes through VYNL. If no sound comes through, the EQ turns itself off after a few seconds so your Mac is never left silent. Re-allow it under System Settings > Privacy & Security > Screen & System Audio Recording.
- **Speech Recognition:** asked the first time VYNL writes down lyrics for a song that isn't in the lyrics database. It runs on your Mac.
- **Automation (Spotify, Music):** asked when you set VYNL to follow Spotify or Apple Music, search your Music library, or if the Now Playing helper is missing and VYNL falls back to controlling Spotify directly. Change it under System Settings > Privacy & Security > Automation.

Turning the EQ off, or quitting VYNL, puts audio back to normal immediately.

## Tweaks

Run these in Terminal, then quit and reopen VYNL:

```
defaults write com.spencermarchant.vynl topOffset -float 8   # move the record lower, e.g. under SketchyBar
defaults write com.spencermarchant.vynl side right           # top right instead of top left
```

## For developers

VYNL used to be called DevDock, which is still the name of some folders and code. Other ways to build: `scripts/bundle.sh` (app only), `scripts/fetch-adapter.sh` (Now Playing helper only), or open `Package.swift` in Xcode. Use the bundled app for real testing: permission prompts only work properly for a `.app`, not `swift run`.

The app icon is `Resources/AppIcon.icns`, made by `Design/make_icon.py` (change the two gradient colors at the top to recolor it).

## Credits

Now Playing access uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg (BSD-3-Clause), downloaded by `scripts/fetch-adapter.sh`. Lyrics come from [LRCLIB](https://lrclib.net), a free, open lyrics database. Apple Music catalog search uses Apple's public iTunes Search API.
