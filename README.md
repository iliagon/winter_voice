# Dictation (MacVoice fork)

**Hold Fn. Speak. Release. The text is typed where your caret is.**

A personal fork of [MacVoice](https://github.com/winterzxzz/winter_voice) by Winter (MIT), trimmed to one job: push-to-talk dictation through your own OpenAI-compatible transcription endpoint, with a small indicator that appears right at the text caret.

## How it works

1. **Hold Fn** (or any key you set under Shortcuts) in any text field.
2. A pill appears just below the caret with a live waveform while you speak.
3. **Release.** The pill switches to a spinner while your endpoint transcribes.
4. A checkmark draws in, the text is inserted at the caret, and the pill fades out.

If the caret cannot be located (some Chromium/Electron fields), the pill appears below the field, or at the mouse pointer. Errors show as a short card in the same place and disappear after a few seconds.

## Differences from upstream

| Upstream MacVoice | This fork |
|---|---|
| Local whisper.cpp models or a remote API | Remote OpenAI-compatible API only (`POST {base}/audio/transcriptions`) |
| Floating draggable pill at the bottom of the screen, three styles | Click-through pill at the text caret, only during a dictation |
| Listening → idle pill | Listening → transcribing spinner → drawn checkmark → fade |
| In-app updater from upstream GitHub releases | Removed |
| Word-replacement dictionary, usage statistics | Removed |
| Bundle ID `com.winterzxzz.WinterVoice` | `com.iliagon.Dictation` |

Kept as-is: configurable hotkey (hold or toggle), insertion through Accessibility with a clipboard/⌘V fallback that restores the clipboard, secure-field detection, local history, microphone selection, launch at login.

## Setup

- **Permissions:** Microphone, Input Monitoring (the global hotkey), and Accessibility (reading the caret and inserting text). The first-launch guide walks through them.
- **Globe key:** set *System Settings → Keyboard → Press 🌐 key to* **Do Nothing**, otherwise macOS also switches the input source or opens the emoji picker on every dictation.
- **Transcription:** Settings → Transcription: base URL (e.g. `https://api.openai.com/v1`), model (e.g. `whisper-1`), optional API key and language.

## Build

Requirements: Apple Silicon, macOS 14+, Xcode 26.

```bash
ruby scripts/generate-project.rb
```

```bash
xcodebuild -project WinterVoice.xcodeproj -scheme WinterVoice -configuration Debug build
```

The Xcode project is generated from `scripts/generate-project.rb` (needs the `xcodeproj` gem); regenerate it after adding or removing source files. The app signs with an Apple Development identity so macOS keeps its permissions across rebuilds. `open MacVoice.app --args -WVWidgetDemo` loops the pill through every state without a microphone.

Plan and progress of the fork: [docs/FORK-PLAN.md](docs/FORK-PLAN.md). Upstream developer notes (partly outdated for this fork): [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

MIT, see [LICENSE](LICENSE). Original work © 2026 Winter (winterzxzz).
