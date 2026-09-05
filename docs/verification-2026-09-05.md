# Native UI and reliability verification

Review date: September 5, 2026. Checkout: `nhwoodward/Lowkey`, based on
`d3a52087b5f5f7357f49fd4ae13241dfa62a8909`. At audit time, changes were local
and uncommitted. This document records the verification completed before release.

## Environment

Apple silicon, macOS 27 beta (26A5416b), Swift 6.4 and Xcode beta. Interactive
testing used `dist/Lowkey Development.app`, bundle ID `app.lowkey.development`,
port 18791, Right Option shortcut, and private data in `dist/development-support`.
The installed Lowkey app and its history were not replaced. Existing downloaded
speech models were reused initially. The later language fix downloaded Parakeet
v2 through FluidAudio. Development preferences were restored to System
appearance, English, and Parakeet after the initial testing. Subsequent user
changes to Dock visibility, the resting bar, login, and media pause were preserved.

## Corrections

- Imported audio now remains owned by its original location. History stores a
  copy, and accepted audio formats are normalized before transcription.
- Whisper can restart after being retired while Parakeet is healthy. Explicit
  shutdown still rejects late work. Engine callbacks reject stale generations.
- HTTP error pages and malformed responses can no longer become transcripts.
- Recording and import work is serialized. Configuration is captured per take;
  engine changes wait for active work to finish. Each recording has its own file.
- Paste delivery checks its destination, retains complete clipboard
  representations, and avoids overwriting a newer clipboard change. Subprocess
  output is drained while the child runs so a full pipe cannot deadlock delivery.
- Side-specific modifier release is recognized even while the other side remains
  held. Selected-microphone failures are surfaced instead of silently rerouting.
- The floating panel uses AppKit Liquid Glass on macOS 26+, with a visual effect
  fallback. The idle microphone starts recording; clicking the waveform finishes,
  and Escape cancels. Reduced Motion is
  respected. Settings use a native preference toolbar and grouped SwiftUI forms;
  history uses a standard window and toolbar.

## Results

| Check | Result | Evidence and boundary |
| --- | --- | --- |
| Debug compilation | PASS | `dist/language-launch.log`; updated isolated development app launched successfully. |
| Release compilation | PASS | `swift build -c release`; `dist/language-release.log`. |
| Automated regressions | PASS | 13 XCTest tests, zero failures; `dist/language-tests.log`. |
| Import ownership | PASS | Reproduced original-file disappearance with the original implementation. After the fix, actual UI import and history deletion preserved the original SHA-256. |
| Parakeet import | PASS | Real 7-second speech fixture produced the expected sentence; 1.23-second transcription logged at 05:08:18 UTC. |
| Whisper import | PASS | Same fixture produced the expected sentence; 0.44-second transcription logged at 05:13:15 UTC. |
| Physical microphone capture | PASS | Played the generated fixture through speakers and recorded the physical microphone. Both engines produced speech transcripts through the bar. |
| Microphone accuracy | LIMITED | Parakeet's recorded fixture matched the sentence apart from name punctuation. The later Whisper speaker-to-microphone take contained substitutions such as "lazy dock". These are functional checks, not an accuracy benchmark. |
| Finish, Cancel, local Escape | PASS | Finish produced a saved transcript. Cancel and Escape sent to Lowkey returned the bar to Start without adding history entries. Global Escape still needs a physical keyboard check. |
| History playback | PASS | Play changed to Stop and returned to Play. |
| Light/dark settings | PASS | Inspected General, Dictation, and Privacy screenshots and AX trees. Toolbar selection follows the selected page. |
| Keyboard window commands | PASS | Command-comma opened Settings; Command-W closed native windows. |
| Clipboard fallback | PASS | Without Accessibility, the app reported that paste could not finish. Manual Command-V in the test TextEdit document inserted the recognized transcript. |
| Automatic TextEdit paste | PASS | History insertion at 05:41:08 UTC logged `app=TextEdit trusted=true`, followed by `outcome=succeeded restore=true`. AX inspection confirmed the inserted sentence. |
| Microphone to automatic paste | PASS | At 05:41:46 UTC, a fresh physical-microphone take transcribed through Parakeet in 0.55 seconds and inserted into TextEdit. The document visibly gained the recognized sentence. |
| Clipboard modes | PASS | Real TextEdit insertion passed with If paste fails, Always, and Never. If paste fails and Never restored the distinct clipboard sentinel; Always retained the delivered transcript. Verified through paste logs and clipboard reads. |
| Browser paste | PASS | Chrome's local textarea received the exact 114-character fixture and one trusted paste event. Lowkey's AX detection returned unknown and conservatively retained the clipboard. |
| Focus changes while recording | PASS | Started with Chrome as target, switched to TextEdit before finishing. Lowkey logged `destination changed; preserving transcript without typing`; both documents remained unchanged and the bar reported clipboard fallback. This does not test a switch during the brief keystroke-posting interval. |
| Global hold-to-talk shortcut | PASS (user test) | The user completed the requested physical TextEdit test and supplied a screenshot at 08:18 EDT. Matching logs at 12:17:54-55 UTC show microphone release, Parakeet recognition, and successful TextEdit insertion with clipboard restoration. The screenshot does not independently establish recognition accuracy against the spoken words. |
| WezTerm delivery | PASS (user test) | The user tested WezTerm. Five attempts from 12:23:40 through 12:23:57 UTC resolved pane 0, completed `wezterm send-text`, and restored the previous clipboard. The first attempt exposed the separate recognition defect described below. |
| Apple Terminal delivery | UNRESOLVED | Computer Use explicitly refused `com.apple.Terminal` for safety reasons. No alternate automation was used to bypass that refusal. The disposable receiver was stopped. Later logs contain two Terminal attempts at 12:17:05 and 12:17:08 UTC, both reported failed; the active terminal session and visible result are unknown. |
| Wrong-language English recognition | PASS after fix | Three saved recordings that had produced Cyrillic now each produce `Testing.` with the English-only recognizer. The original reported clip also passed through the updated app's Import Audio flow. |
| Forced live Core ML failure | NOT RUN | Recovery was tested with the production Engine class and a real mock HTTP subprocess; both real recognizers were tested separately. No Core ML failure was forced in the live app. |
| Other macOS versions / Intel | NOT RUN | No macOS 14, 15, or 26 runtime or Intel machine was available in this run. |
| Release packaging / CI | NOT RUN | Workflow changes are local. Remote CI, notarization, and a fresh downloaded installation were not executed. |

The preserved original fixture is `dist/review-fixtures/import-original.wav`
(217,364 bytes). SHA-256 before import, after import, and after deleting the
history copy:

```text
768f78f121c93525e5e522b4b83077f78927575eaecf910caa8eab3de3f36401
```

Timing values above are individual observed runs. Cold Parakeet initialization
varied substantially with system load, including a 42-second run. No fixed
latency or memory claim is established by this testing.

Early UI actions operated background windows without activating their apps.
Paste logs therefore show `Ryspar-Dev` as the captured destination in the
denied-permission tests. Opening a new local text fixture through Finder
established TextEdit as the actual foreground app, confirmed through
NSWorkspace. Subsequent automatic insertion tests used that real destination.

The local interactive fixtures are `dist/review-fixtures/paste-delivery-target.txt`
and `dist/review-fixtures/paste-target.html`. Chrome's page records the trusted
paste event and field value. No browser field was filled through automation to
stand in for Lowkey insertion.

## English recognition correction

The user reported foreign-language output for a short English utterance during
the WezTerm test. The app was configured with `language=en` but always loaded
multilingual Parakeet v3 without a language hint. The same saved 1.39-second
recording reproducibly returned `Кастинг.` through the unchanged recognizer,
while another recording returned `Testing.`. This was a recognition defect;
WezTerm delivered the recognizer's output correctly in both cases.

English recognition now loads
[Parakeet v2's English-only model](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml).
Auto detect and non-English languages route to multilingual Whisper. A regression
test checks that those routes choose the multilingual fallback without replacing
the stored English model preference. The model version is logged at readiness.

The reported recording's SHA-256 is
`f148e14d6355d2482e76a099cce1cf4b6b08e7bf64ae52d672ad1cb6767375aa`.
It produced `Testing.` on repeated replays after the fix. Two additional saved
Cyrillic failures also produced `Testing.`. The English control clips and longer
generated sentence remained correct. Finally, importing the original failing
recording through the updated native UI produced `Testing.` at 12:34:24 UTC.
The new app logged `parakeet ready model=v2` and retained both privacy grants.

Evidence: `dist/language-before.log`, `dist/language-after.log`,
`dist/language-all-failures-after.log`, and the development app's history/logs.
The first v2 load took 236 seconds including its download; the next app launch
initialized it in 25 seconds under current system load. This is not a fixed
startup-time or general recognition-accuracy guarantee.

## Automated coverage

### Voice bar sizing and motion follow-up

The user's live screenshot reproduced the oversized `Nothing heard` state.
The old error layout allocated 360 x 64 points regardless of text, compared with
152 x 48 while listening. A regression test reproduced this mismatch before the
fix (`dist/voice-bar-layout-before.log`). Every state now uses 48-point glass
height, plus an unchanged 6-point optical margin on each side of the panel.
Text widths use native cell sizing, including the text field's internal padding;
bare glyph measurements had visibly cut off short messages. There is no ellipsis
truncation. Long technical diagnostics use a complete compact explanation, with
the full diagnostic in the tooltip and accessibility help. Screen-constrained
panels remain centered using their actual width.

The original waveform-to-ring-to-checkmark animation was restored from the repo
and adapted to the native glass surface. Processing and completion hug a centered
glyph; width changes and waveform dissolution preserve height. Message text fades
in after expansion, so the resize does not expose partial words. Reduced Motion
uses static ring/check states without the spin, stroke, or resize animations.

Native UI preview frames verified full short, noise, save, engine, paste-failure,
and long-diagnostic messages, the finishing state, and the ring closing into the
checkmark. This was a deterministic display-state audit, not forced live engine
or permission failures. Five new tests cover message geometry, repeated state
changes, long/multiline/empty/Unicode diagnostics, screen centering, completion
animation cleanup, and the static animation path. The full suite passed 18 tests
with zero failures (`dist/voice-bar-tests.log`). Normal dictation mode is restored
after the preview; user preferences are preserved.

The tests cover original audio preservation, retirement/restart/shutdown,
HTTP errors and malformed bodies, empty and multi-format clipboard restoration,
new clipboard ownership, modifier-key release, stereo 44.1 kHz conversion to
mono 16 kHz, large subprocess output, and bounded subprocess runtime. They use
temporary files and private pasteboards. Shell syntax and `git diff --check`
also passed.

## Remaining acceptance work

The user completed the requested physical hold-to-talk test in TextEdit. Its
matching 120-character transcript took 0.46 seconds to recognize and was logged
as successfully inserted at 08:17:55 EDT, with the previous clipboard restored.
Global Escape still needs a physical check. Apple Terminal delivery needs
investigation of the two later failed attempts; the tool refused terminal access.
WezTerm's direct CLI delivery passed the user's later test. A focus switch specifically during inference or keystroke
posting also remains unverified; the completed check switched apps before Finish.

At 01:32 EDT the user confirmed approval and provided a screenshot of the enabled
entry. The development app still returned untrusted after restarting. The system
log explicitly reported `Failed to match existing code requirement` for
`app.lowkey.development` and `kTCCServiceAccessibility`: the stored requirement
was an earlier ad-hoc code hash, while the current build has a Developer ID
requirement. `codesign --verify --deep --strict` passed for the current bundle.
Evidence is in `dist/accessibility-identity.log`. After the user completed Touch
ID, the selected development entry was removed and the current signed bundle
was added through System Settings. Lowkey immediately reported Accessibility
Allowed and actual automatic paste succeeded. Other applications' permission
entries were not changed.

Run the resulting build on supported older macOS versions and Intel, and run the
release workflow before calling this release fully production-validated.
