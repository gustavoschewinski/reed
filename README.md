# Reed

Hold or tap a shortcut, speak, and the text appears in whatever app has focus — dictation that runs entirely on your Mac.

## Install

Download the DMG from [Releases](https://github.com/gustavoschewinski/reed/releases), open it, and drag Reed to Applications.

Reed isn't notarized yet, so the first launch needs one extra step: macOS will say it can't verify the developer. Right-click (or Control-click) Reed in Applications and choose **Open**, or go to System Settings → Privacy & Security and click **Open Anyway** next to the Reed warning. You only need to do this once.

```bash
brew install --cask gustavoschewinski/tap/reed
```

This will work once the `gustavoschewinski/tap` Homebrew tap exists — it doesn't yet, so this command fails today. Until then, use the DMG above.

## First run

Reed asks for two permissions (below), then downloads its speech model — about 600 MB, shown with a real progress bar — and compiles it for the Neural Engine, a one-time step that takes roughly 20 seconds. None of this repeats on later launches. After that, pick a shortcut and you're dictating.

## Permissions

- **Microphone** — to hear you. Audio is only captured while you're actively dictating.
- **Accessibility** — so Reed can paste the transcribed text into whatever app has focus, instead of just leaving it on the clipboard.

Reed does **not** need Input Monitoring.

## Privacy

Transcription runs on-device using NVIDIA's Parakeet TDT v3 on the Neural Engine — nothing you say leaves your Mac. Audio is discarded the moment transcription finishes and is never written to disk; only the resulting text is stored, in your local history. The only network request Reed ever makes is the one-time model download on first run.

25 languages are supported, auto-detected, including Portuguese and English. Measured on an M3, transcription runs about 23x real time — 2.79 seconds of speech takes 0.123 seconds to transcribe.

## Troubleshooting

**Reed doesn't seem to hear me at all — the pill appears but nothing ever gets typed or copied.** This is almost always the microphone permission, and it's the quietest failure Reed has: a denied or unavailable microphone looks identical to a genuinely quiet room. Check System Settings → Privacy & Security → Microphone and make sure Reed is enabled — Settings within the app will also show a notice here when this is the cause.

**The text doesn't appear in my app.** This almost always means Accessibility permission was skipped or dismissed during setup. Reed still transcribes correctly — the text is just left on the clipboard instead of typed in. Open Reed's Settings, or go to System Settings → Privacy & Security → Accessibility, and enable Reed. Paste the clipboard content in the meantime with ⌘V.

**Nothing happens on the first launch.** The 600 MB model download and the one-time Neural Engine compile (~20 seconds) both happen before Reed is ready — watch for the progress bar rather than assuming it's hung.

**Debug logging.** If something above doesn't explain what you're seeing, launch Reed with debug logging turned on:

```bash
REED_DEBUG_LOG=1 /Applications/Reed.app/Contents/MacOS/Reed
```

This writes a step-by-step trace of the dictation pipeline (recording start, mute/media-pause, transcription passes, delivery, overlay show/hide) to `~/Library/Logs/Reed/reed-debug.log`. It's off unless that environment variable is set — a normal launch never creates or writes this file. The log is safe to share: it records lengths, counts, and state names, never the words you dictated.

## Known limitations

- **Non-QWERTY keyboard layouts.** Pasting works by synthesizing ⌘V using the physical key code for V on a US-ANSI keyboard. On Dvorak, Colemak, or other non-QWERTY layouts, that paste may not fire in every app. The transcribed text is always still on the clipboard, so ⌘V (or Edit → Paste) recovers it.

## Building from source

Requires Xcode 26.6+ and macOS 14+.

```bash
swift build
swift test
./Scripts/build-app.sh   # produces build/Reed.app
./Scripts/install.sh     # builds, then installs to /Applications and launches
./Scripts/make-dmg.sh    # produces build/Reed.dmg
```

Use `install.sh` for anything past a smoke test. `build-app.sh` leaves the app in `build/`, and running Reed from there means a second bundle with the same identifier competing with the installed one — it is easy to end up debugging a stale binary. `install.sh` also registers the app with LaunchServices and Spotlight, which a plain copy does not do: Reed has no Dock icon, so ⌘-Space is how you open it.

`Scripts/make-icon.sh` regenerates `Resources/Reed.icns` from its vector source if you want to change it.

## Third-party licences

Reed's DMG bundles FluidAudio (Apache-2.0) and KeyboardShortcuts (MIT). Their licence texts are included in the app bundle and in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT — see [LICENSE](LICENSE).
