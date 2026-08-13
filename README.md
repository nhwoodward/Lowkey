# Whisperly

Local-only dictation for macOS. Hold Right Command, speak, release. Whisper
small runs on the same Mac through `whisper-server` bound to `127.0.0.1`.
No account. No analytics. No cloud.

## Requirements

- macOS 14 or later
- [Homebrew](https://brew.sh) `whisper-cpp` (`whisper-server` on your `PATH`)
- A local Whisper model, typically `ggml-small.bin`

## Use

1. Build and install with `./Scripts/bundle.sh`, then open `~/Applications/Whisperly.app`.
2. Put the model at `~/Library/Application Support/Whisperly/models/ggml-small.bin`.
3. Grant Microphone and Accessibility when macOS asks.
4. Hold **Right Command** (or the shortcut you set), talk, let go.
5. The Flow Bar shows a live waveform, then a spinner, then a check when the words are ready.
6. Press **Esc** while holding the shortcut to discard the current recording.
7. Text is pasted into the focused app. If paste is blocked, the transcript stays on the clipboard.

## Files

- App: `~/Applications/Whisperly.app`
- Model: `~/Library/Application Support/Whisperly/models/ggml-small.bin`
- Config: `~/Library/Application Support/Whisperly/config.json`
- Logs: `~/Library/Application Support/Whisperly/logs/`

## Rebuild

```bash
./Scripts/bundle.sh
open ~/Applications/Whisperly.app
```

## Signing

Local builds use **Hardened Runtime** and a self-signed `Whisperly Local`
certificate so Microphone and Accessibility stay granted across rebuilds.
Signing keys stay in Application Support and are not in this repo.

**Notarization** is a separate Apple scan for giving the app to other Macs.
It needs a paid Apple Developer Program membership and a Developer ID
certificate:

```bash
xcrun notarytool store-credentials whisperly-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD
./Scripts/bundle.sh
./Scripts/notarize.sh
```

