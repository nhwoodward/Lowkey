# Whisperly

Local-only dictation for macOS. Hold Right Command, speak, release. Whisper
small runs on the same Mac through `whisper-server` bound to `127.0.0.1`.
No account. No analytics. No cloud.

Licensed under the [MIT License](LICENSE).

## Install

Needs [Homebrew](https://brew.sh) and the Xcode Command Line Tools. First run
downloads the small Whisper model (~466 MB) and builds the app.

```bash
curl -fsSL https://raw.githubusercontent.com/nhwoodward/Whisperly/main/Scripts/install.sh | zsh
```

Or from a clone:

```bash
./Scripts/install.sh
```

Then grant Microphone and Accessibility when macOS asks. Hold **Right Command**,
speak, release. Press **Esc** while holding to discard.

## Use

1. Hold **Right Command** (or the shortcut you set), talk, let go.
2. The Flow Bar shows a live waveform, then a spinner, then a check when the words are ready.
3. Press **Esc** while holding the shortcut to discard the current recording.
4. Text is pasted into the focused app. If paste is blocked, the transcript stays on the clipboard.

## Privacy

Audio and transcripts stay on the Mac. The engine listens only on
`127.0.0.1`. There is no account, no analytics, and no network call
except that local server. History and logs live under
`~/Library/Application Support/Whisperly/` and are not part of this
repository.

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

