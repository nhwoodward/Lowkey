<h1 align="center">Lowkey</h1>

<p align="center">
  <a href="#quick-start"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square" /></a>
  <a href="#what-it-is"><img alt="8 GB of RAM and up" src="https://img.shields.io/badge/RAM-8%20GB%2B-111111?style=flat-square" /></a>
  <a href="#privacy"><img alt="Parakeet on the Neural Engine, Whisper fallback" src="https://img.shields.io/badge/engine-Parakeet%20%2B%20Whisper-111111?style=flat-square" /></a>
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

Lowkey uses the one processor nothing else is fighting over.

Hold **Right Command**, talk, let go. [NVIDIA Parakeet](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) runs on the **Apple Neural Engine** inside the app itself: no server, no GPU time, and dictation stays fast even while the rest of the machine compiles, renders, or swaps. The words land wherever the cursor is. A short utterance transcribes in about a quarter of a second; a half-minute monologue in about one.

Whisper stays on board as the safety net. It covers dictation while Parakeet's model downloads on first launch, takes over automatically if Parakeet ever fails, and handles non-English dictation.

<p align="center">
  <img alt="Lowkey dictation window" src="docs/images/window.png" width="86%" />
</p>

## Features

- **Hold to talk** - Right Command by default. Switch to Left Command, Right Option, or Fn. Press **Esc** while holding to discard the take.
- **Neural Engine first** - Parakeet TDT (int8) transcribes in-process on the ANE. It is immune to GPU contention and thermal throttling, and the app idles under 30 MB because the ANE manages the model's memory.
- **Whisper as the fallback** - `whisper-server` on `127.0.0.1` with `ggml-small.en-q5_1`, greedy decode, and encoder cropping sized to the clip. If Parakeet is unavailable for any reason, dictation still works.
- **Warm before you finish talking** - engines pre-heat when recording starts, so the audio always hits a hot pipeline.
- **Spoken pauses stay spoken** - segment breaks, stray ellipses, and the capitalization glitches they cause are cleaned out of the transcript instead of pasted into your text.
- **Paste, then keep the words** - sends directly to the focused WezTerm pane when WezTerm is active, or uses a keystroke paste elsewhere. If delivery cannot land, the transcript is still on the clipboard.
- **Your names, your phrases** - custom vocabulary for names and spelling, plus spoken snippets that expand into saved text.
- **History stays here** - replay, recopy, or delete. Audio and transcripts live under Application Support, not this repository.
- **Menu bar, not a dock hog** - hide from the Dock, start at login, optionally pause Music or Spotify while you talk.
- **Hardened Runtime** - local builds are signed with a self-signed `Lowkey Local` identity so Microphone and Accessibility survive rebuilds.

<p align="center">
  <img alt="General settings" src="docs/images/settings.png" width="48%" />
  <img alt="Dictation settings" src="docs/images/settings-dictation.png" width="48%" />
</p>

## Quick Start

### Requirements

- macOS 14 or later. Apple Silicon for the Neural Engine; Intel Macs run on the Whisper engine alone
- About 8 GB of RAM or more
- [Homebrew](https://brew.sh) and the Xcode Command Line Tools

### Download the latest release (recommended)

GitHub Releases contain prebuilt apps. The release installer downloads the correct build, installs the Whisper fallback engine, and fetches its model. It does not clone the repository or compile Swift:

```bash
curl -fsSL https://raw.githubusercontent.com/nhwoodward/Lowkey/main/Scripts/install-release.sh | zsh
```

You can also download an archive manually from the [Releases page](https://github.com/nhwoodward/Lowkey/releases/latest): choose `Lowkey-arm64.zip` for Apple silicon. (`Lowkey-x86_64.zip` exists for Intel Macs, which have no Neural Engine and run on the Whisper engine alone.) The installer script is recommended because the app also needs `whisper-server` and its fallback model.

### Build from source

If you want to work on Lowkey or build locally:

```bash
git clone https://github.com/nhwoodward/Lowkey.git
cd Lowkey
./Scripts/install.sh
```

The installer fetches the Whisper fallback model (~181 MB); Lowkey downloads the Parakeet model (~500 MB) on first launch and dictates through Whisper until it is ready. Grant **Microphone** and **Accessibility** when macOS asks. Hold **Right Command**, speak, release. Press **Esc** while holding to discard.

## How it works

```
        you hold Right Command
                  │
                  ▼
        ┌──────────────────┐
        │ Flow Bar         │  live waveform while you talk
        └────────┬─────────┘
                 ▼
        ┌──────────────────┐     ┌──────────────────┐
        │ Parakeet TDT     │ ──▶ │ whisper-server   │  fallback
        │ Neural Engine,   │     │ 127.0.0.1:18789  │  first launch,
        │ in-process       │     │ small.en-q5_1    │  errors, non-English
        └────────┬─────────┘     └────────┬─────────┘
                 ▼                        ▼
        words paste at the cursor
        clipboard is the failsafe
```

You talk to one shortcut. Lowkey records 16 kHz PCM on this Mac and transcribes it on the Neural Engine, in-process. The transcript is cleaned (pause artifacts out, your vocabulary in) and delivered to the app that had focus. WezTerm receives it through its CLI; other apps receive a keystroke paste. If delivery will not land, Cmd+V still has the same text.

Why the Neural Engine matters: on a working Mac the CPU and GPU are shared with everything else - builds, browsers, compositing - and dictation queues behind all of it. The ANE is idle on almost every machine, so transcription time stays flat whether the Mac is quiet or under full load.

## Privacy

Audio and transcripts stay on the Mac.

- Parakeet runs inside the app process. The Whisper fallback listens only on `127.0.0.1`. There is no account, no analytics, and no outbound call for transcription. The only downloads are the models themselves, fetched once from Hugging Face.
- `~/Library/Application Support/Lowkey/` is created mode `700`. History, config, and logs live there. They are not part of this repository.
- Signing keys stay in Application Support. They are gitignored.
- Hardened Runtime is on. The entitlements are microphone input and Apple Events for paste, nothing else.

## Files

- App: `~/Applications/Lowkey.app`
- Parakeet model: `~/Library/Application Support/FluidAudio/Models/`
- Whisper fallback model: `~/Library/Application Support/Lowkey/models/ggml-small.en-q5_1.bin`
- Config: `~/Library/Application Support/Lowkey/config.json` (`"engine": "parakeet"` or `"whisper"`)
- Logs: `~/Library/Application Support/Lowkey/logs/`

## Rebuild

```bash
./Scripts/bundle.sh
open ~/Applications/Lowkey.app
```

To create a release archive locally:

```bash
LOWKEY_VERSION=2.0.0 ./Scripts/package-release.sh
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

Primary speech recognition is [NVIDIA Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0), run on the Apple Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio)'s CoreML conversion. Fallback recognition is [OpenAI Whisper](https://github.com/openai/whisper) (MIT) through [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `whisper-server`.

Lowkey is an independent Mac app. It is not affiliated with NVIDIA, OpenAI, Fluid Inference, or whisper.cpp.

## License

MIT. See [LICENSE](LICENSE).
