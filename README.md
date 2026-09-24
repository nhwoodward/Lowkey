<h1 align="center">Lowkey</h1>

<p align="center">
  <a href="#quick-start"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square" /></a>
  <a href="#what-it-is"><img alt="8 GB of RAM and up" src="https://img.shields.io/badge/RAM-8%20GB%2B-111111?style=flat-square" /></a>
  <a href="#privacy"><img alt="Parakeet or Whisper, one engine at a time" src="https://img.shields.io/badge/engine-Parakeet%20%2B%20Whisper-111111?style=flat-square" /></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" /></a>
</p>

<h3 align="center">Hold a key. Speak. Stay on this Mac.</h3>

<p align="center">
  Local dictation on the Apple Neural Engine, for machines with 8 GB of RAM and up.
  No account. No analytics. No cloud.
</p>

<p align="center">
  <img alt="Lowkey: hold a key, speak, stay on this Mac" src="docs/images/banner.png" width="100%" />
</p>

## What it is

Cloud dictation wants an account, a subscription, and your audio. Local dictation usually wants your GPU, and on a busy 8 GB Mac the GPU is already spoken for.

Lowkey gives local speech recognition a dedicated path through Apple's Neural Engine.

Hold **Right Command**, talk, let go. [NVIDIA Parakeet v2](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) runs on the **Apple Neural Engine** inside the app itself: no separate server for primary recognition. Its English-only vocabulary keeps English dictation from switching to another language. The words land wherever the cursor is. Recognition time varies with the recording and current system load.

Choose Parakeet or Whisper in Settings > Dictation. Only the selected engine loads into memory. Switching engines unloads the previous model before loading the next; recordings already in progress finish first. Lowkey never starts the other engine automatically, including during downloads or after errors. Whisper supports Intel Macs and non-English dictation with a multilingual model.



## Features

- **Hold to talk, double-tap for hands-free** - Right Command by default; switch to Left Command, Right Option, or Fn. Release to insert. Double-tap to keep listening, then press once more or click the bar to finish. **Esc** discards the take. Shortcuts stay shortcuts: pressing another key or clicking while you hold (Right Command-C, Command-click) cancels silently, with no sound or bar.
- **Native macOS interface** - system toolbars and grouped settings. The floating bar uses Liquid Glass on macOS 26+, with an adaptive material on macOS 14 and 15. It counts down the last 10 seconds of the two-minute limit, and a message with a fix (such as allowing Accessibility) opens it when clicked.
- **Guided setup** - the first launch checks Microphone, Accessibility, and the speech model download with live status. Granting Accessibility takes effect without a relaunch. The menu bar icon shows a badge while anything still needs attention.
- **Neural Engine first** - Parakeet TDT (int8) transcribes in-process on the ANE. This keeps the primary recognition workload off the GPU. Performance and memory use depend on the model, audio, hardware, and current system load.
- **Whisper when selected** - `whisper-server` on `127.0.0.1` with `ggml-small.en-q5_1`, greedy decode, and encoder cropping sized to the clip. Choose it in Dictation settings when you need a different recognizer.
- **Ready before recording** - the selected model loads before dictation begins. Whisper also warms when recording starts to reduce its idle wake-up cost.
- **Spoken pauses stay spoken** - segment breaks, stray ellipses, and the capitalization glitches they cause are cleaned out of the transcript instead of pasted into your text.
- **Paste, then keep the words** - sends directly to the focused WezTerm pane when WezTerm is active, or uses a keystroke paste elsewhere. If delivery cannot land, the bar says where the words are: on the clipboard, or in History when clipboard copies are turned off. **Paste Last Dictation** in the menu bar sends it again.
- **Your names, your phrases** - custom vocabulary for names and spelling, plus spoken snippets that expand into saved text.
- **History stays here** - replay, recopy, or delete. Imported audio is copied and normalized, and original files remain untouched. Double-click a history entry to read or copy its full text. Audio and transcripts live under Application Support, not this repository.
- **Menu bar, not a dock hog** - hide from the Dock, start at login, optionally pause Music or Spotify while you talk.
- **Hardened Runtime** - local builds are signed with a self-signed `Lowkey Local` identity so Microphone and Accessibility survive rebuilds.



## Quick Start

### Requirements

- macOS 14 or later. Apple Silicon for the Neural Engine; Intel Macs run on the Whisper engine alone
- Xcode 26 or later when building with Liquid Glass support (older toolchains use the material fallback)
- About 8 GB of RAM or more
- [Homebrew](https://brew.sh) and the Xcode Command Line Tools

### Download the latest release (recommended)

GitHub Releases contain prebuilt apps. The release installer downloads the correct build, installs the Whisper engine, and fetches its model. It does not clone the repository or compile Swift:

```bash
curl -fsSL https://raw.githubusercontent.com/nhwoodward/Lowkey/main/Scripts/install-release.sh | zsh
```

You can also download an archive manually from the [Releases page](https://github.com/nhwoodward/Lowkey/releases/latest): choose `Lowkey-arm64.zip` for Apple silicon. (`Lowkey-x86_64.zip` exists for Intel Macs, which have no Neural Engine and run on the Whisper engine alone.) The installer script is recommended because the app also needs `whisper-server` and its model.

### Build from source

If you want to work on Lowkey or build locally:

```bash
git clone https://github.com/nhwoodward/Lowkey.git
cd Lowkey
./Scripts/install.sh
```

The installer fetches the Whisper model (~181 MB); Lowkey downloads the Parakeet model (~500 MB) when Parakeet is selected. Downloaded models stay on disk when you switch; they do not both stay loaded in memory. On first launch, the setup window asks for **Microphone** and **Accessibility** and shows the model download. Hold **Right Command**, speak, release. Press **Esc** to discard.

## How it works

```
        you hold Right Command
                  │
                  ▼
        ┌──────────────────┐
        │ Flow Bar         │  live waveform while you talk
        └────────┬─────────┘
                 ▼
        ┌──────────────────────────────────────────┐
        │ Selected engine only                     │
        │ Parakeet: Neural Engine, in-process       │
        │ OR Whisper: local server, 127.0.0.1:18789 │
        └────────┬─────────────────────────────────┘
                 ▼
        words paste at the cursor
        clipboard is the failsafe
```

You talk to one shortcut. Lowkey records 16 kHz PCM on this Mac and transcribes it locally with the selected engine. The transcript is cleaned (pause artifacts out, your vocabulary in) and delivered to the app that had focus. WezTerm receives it through its CLI; other apps receive a keystroke paste. If delivery will not land, Cmd+V still has the same text.

Why the Neural Engine matters: on a working Mac the CPU and GPU are shared with everything else - builds, browsers, compositing - and dictation queues behind all of it. Running Parakeet through Core ML reduces reliance on the GPU for primary transcription; it does not guarantee constant latency under load.

## Privacy

Audio and transcripts stay on the Mac.

- Parakeet runs inside the app process. The Whisper server listens only on `127.0.0.1`. There is no account, no analytics, and no outbound call for transcription. The only downloads are the models themselves, fetched once from Hugging Face.
- `~/Library/Application Support/Lowkey/` is created mode `700`. History, config, and logs live there. They are not part of this repository.
- Signing keys stay in Application Support. They are gitignored.
- Hardened Runtime is on. The entitlements are microphone input and Apple Events for paste, nothing else.

## Files

- App: `~/Applications/Lowkey.app`
- Parakeet model: `~/Library/Application Support/FluidAudio/Models/`
- Whisper model: `~/Library/Application Support/Lowkey/models/ggml-small.en-q5_1.bin`
- Config: `~/Library/Application Support/Lowkey/config.json` (`"engine": "parakeet"` or `"whisper"`)
- Logs: `~/Library/Application Support/Lowkey/logs/`

## Development and verification

```bash
swift test
./script/build_and_run.sh
```

The development app uses its own bundle identifier, port (18791), shortcut
(Right Option), and data under `dist/development-support`. It does not replace
the installed app or use its dictation history. Grant Microphone and
Accessibility to **Lowkey Development** to test recording and paste delivery.
The run script reuses an existing Developer ID identity, when available, to
keep those grants stable across rebuilds.

Debug builds can render their own windows for visual review without Screen
Recording permission. `LOWKEY_UI` opens a surface (`main`, `settings:<Page>`,
`setup`, `flow-audit`), `LOWKEY_SNAPSHOT_DIR` writes a PNG of every visible
window on a timer, and `LOWKEY_NO_PASTE=1` keeps a review run from typing into
whichever app is in front.

The automated suite covers history ownership, exclusive engine lifecycle, HTTP response
validation, clipboard preservation, audio conversion, modifier handling, and
process timeouts. Physical microphone capture, cross-app paste, and visual
appearance still require interactive validation.

For Auto detect or non-English dictation, select Whisper, the language, and a multilingual Whisper
model in Settings > Dictation. Parakeet remains English-only and does not silently switch engines. An installed `ggml-small.bin`,
`ggml-small-q5_1.bin`, or `ggml-base.bin` alongside the English model is selected
automatically. The default English-only model cannot transcribe other languages.

## Rebuild

```bash
./Scripts/bundle.sh
open ~/Applications/Lowkey.app
```

To create a release archive locally:

```bash
LOWKEY_VERSION=2.1.0 ./Scripts/package-release.sh
```

The GitHub Actions workflow at `.github/workflows/release.yml` builds `Lowkey-arm64.zip` and `Lowkey-x86_64.zip` whenever a `v*` tag is pushed. It also supports manually creating a release from the Actions tab.

## Signing

Local builds use **Hardened Runtime** and a self-signed `Lowkey Local` certificate so Microphone and Accessibility stay granted across rebuilds. Signing keys stay in Application Support and are not in this repo.

Release builds are ad-hoc signed by default so the workflow can run without private Apple credentials. macOS may require a user to right-click an unsigned/unnotarized release and choose **Open** the first time. For a no-warning download, configure these repository secrets with a paid Apple Developer **Developer ID Application** certificate:

- `DEVELOPER_ID_CERTIFICATE_BASE64` - base64-encoded `.p12` export
- `DEVELOPER_ID_CERTIFICATE_PASSWORD` - the `.p12` password
- `LOWKEY_NOTARY_APPLE_ID` - Apple ID used for notarization
- `LOWKEY_NOTARY_TEAM_ID` - Apple Developer Team ID
- `LOWKEY_NOTARY_PASSWORD` - Apple app-specific password

For example, encode the certificate locally with `base64 -i DeveloperID.p12 | pbcopy`, then paste it into the first secret. The workflow imports the certificate, notarizes, staples, and publishes the final archive automatically.

**Notarization** requires a paid Apple Developer Program membership:

```bash
xcrun notarytool store-credentials lowkey-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD
./Scripts/bundle.sh
./Scripts/notarize.sh
```

## Credits

Primary speech recognition is [NVIDIA Parakeet TDT v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (CC-BY-4.0), run on the Apple Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio)'s CoreML conversion. Whisper recognition is [OpenAI Whisper](https://github.com/openai/whisper) (MIT) through [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `whisper-server`.

Lowkey is an independent Mac app. It is not affiliated with NVIDIA, OpenAI, Fluid Inference, or whisper.cpp.

## License

MIT. See [LICENSE](LICENSE).
