# Reed

Hold or tap a hotkey, speak, and the text appears in whatever app has focus — dictation that runs entirely on your Mac.

## Install

```bash
brew install --cask gustavoschewinski/tap/reed
```

Or download the DMG from [Releases](https://github.com/gustavoschewinski/reed/releases) and drag Reed to Applications.

## First run

Reed asks for two permissions (below), then downloads its speech model — about 600 MB, shown with a real progress bar — and compiles it for the Neural Engine, a one-time step that takes roughly 20 seconds. None of this repeats on later launches. After that, pick a hotkey and you're dictating.

## Permissions

- **Microphone** — to hear you. Audio is only captured while you're actively dictating.
- **Accessibility** — so Reed can paste the transcribed text into whatever app has focus, instead of just leaving it on the clipboard.

Reed does **not** need Input Monitoring.

## Privacy

Transcription runs on-device using NVIDIA's Parakeet TDT v3 on the Neural Engine — nothing you say leaves your Mac. Audio is discarded the moment transcription finishes and is never written to disk; only the resulting text is stored, in your local history. The only network request Reed ever makes is the one-time model download on first run.

25 languages are supported, auto-detected, including Portuguese and English. Measured on an M3, transcription runs about 23x real time — 2.79 seconds of speech takes 0.123 seconds to transcribe.

## Troubleshooting

**The text doesn't appear in my app.** This almost always means Accessibility permission was skipped or dismissed during setup. Reed still transcribes correctly — the text is just left on the clipboard instead of typed in. Open Reed's Settings, or go to System Settings → Privacy & Security → Accessibility, and enable Reed. Paste the clipboard content in the meantime with ⌘V.

**Nothing happens on the first launch.** The 600 MB model download and the one-time Neural Engine compile (~20 seconds) both happen before Reed is ready — watch for the progress bar rather than assuming it's hung.

## Known limitations

- **Non-QWERTY keyboard layouts.** Pasting works by synthesizing ⌘V using the physical key code for V on a US-ANSI keyboard. On Dvorak, Colemak, or other non-QWERTY layouts, that paste may not fire in every app. The transcribed text is always still on the clipboard, so ⌘V (or Edit → Paste) recovers it.

## Building from source

Requires Xcode 26.6+ and macOS 14+.

```bash
swift build
swift test
./Scripts/build-app.sh   # produces build/Reed.app
./Scripts/make-dmg.sh    # produces build/Reed.dmg
```

`Scripts/make-icon.sh` regenerates `Resources/Reed.icns` from its vector source if you want to change it.

## License

MIT — see [LICENSE](LICENSE).
