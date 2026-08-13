# Whisperly

Local-only dictation for this Mac. Hold Right Command, speak, release. Whisper small runs on your machine through `whisper-server` bound to `127.0.0.1`. No account. No analytics. No cloud.

## Use

1. Click the waveform in the menu bar and open **Settings**.
2. Grant Microphone and Accessibility when macOS asks.
3. Hold **Right Command** (or the shortcut you set), talk, let go.
4. The Flow Bar at the bottom shows a live waveform, then a spinner, then a check when the words are ready.
5. Press **Esc** while holding the shortcut to discard the current recording.
6. Text is pasted into the focused app. If paste is blocked, use the clipboard setting in Settings to keep the transcript available.

## Files

- App: `~/Applications/Whisperly.app`
- Model: `~/Library/Application Support/Whisperly/models/ggml-small.bin`
- Config: `~/Library/Application Support/Whisperly/config.json`
- Engine log: `~/Library/Application Support/Whisperly/logs/engine.log`
- App log: `~/Library/Application Support/Whisperly/logs/app.log`

## Rebuild

```bash
./Scripts/bundle.sh
open ~/Applications/Whisperly.app
```
