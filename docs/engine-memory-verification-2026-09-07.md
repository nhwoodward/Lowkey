# Exclusive speech engine memory verification

Lowkey now loads only the selected speech engine. Switching waits for the old
engine to release its model before starting the new engine. An in-progress
recording or transcription finishes before a pending settings change takes
effect. Automatic cross-engine fallback has been removed from startup, warmup,
transcription, and recovery. Unsupported Parakeet language or hardware selections
show an actionable error instead of starting Whisper.

## Reproduction

The installed 2.1.0 build 7 app (PID 61829) showed Parakeet and English selected
in native Dictation settings. Its log recorded a Parakeet failure on a clip
shorter than 300 ms at 2026-09-07T20:03:48Z, followed by Whisper recovery and
server PID 30683. Later successful Parakeet dictations did not retire that server.
The server was still a child of the installed app during this review.

`vmmap -summary 30683` measured a physical footprint of **299.6 MiB**. The change
eliminates that unselected process. This is a measurement of the unwanted
Whisper process, not a general app memory benchmark.

A native settings switch from Parakeet to Whisper in the original development
build also left Parakeet's Neural Engine virtual mapping present. The original
Parakeet engine had no unload operation.

## Validation

| Check | Result | Evidence |
| --- | --- | --- |
| Automated regressions | PASS | 25 XCTest tests, zero failures, including late completion of a cancelled Parakeet load, reselection after unloading, explicit Whisper restart, and prevention of cross-engine fallback. |
| Parakeet startup | PASS | Updated development PID 12200 became ready without a Whisper child. |
| Parakeet to Whisper | PASS | Log recorded `parakeet unloaded` before starting Whisper PID 12987. Parakeet's Neural Engine virtual mapping disappeared from the app's `vmmap` summary. |
| Whisper audio import | PASS | Native Import Audio transcribed the seven-second reference fixture correctly. Log: 2026-09-08T02:12:47Z, `engine=whisper`. |
| Whisper to Parakeet | PASS | Log recorded `whisper stopped pid=12987` before Parakeet became ready. Process inspection confirmed the child exited. |
| Short audio import | PASS | A 250 ms WAV imported through the native UI with Parakeet selected created no transcript and did not start Whisper. |
| Parakeet audio import after switching | PASS | Same seven-second reference produced the expected sentence. Log: 2026-09-08T02:19:21Z, `engine=parakeet`. |
| Settings presentation | PASS | Native settings showed the exclusive selection explanation, readiness, and Whisper model controls only when Whisper was selected. |
| Release build | PASS | `swift build -c release --product Lowkey --jobs 2`. |
| Installed app | PASS | Version 2.1.0, build 8, PID 18187, Parakeet ready at 2026-09-08T02:26:38Z. Zero Whisper processes and zero development app processes. |
| Signing | PASS | Deep strict signature verification with the same `app.lowkey.local` identifier and Lowkey Local certificate requirement as build 7. |
| Data preservation | PASS | SHA-256 manifests matched for all 89 preserved data files before backup, in the backup, and after relaunch. Logs, temporary files, and development PID files were excluded. |
| Physical microphone and automatic paste | SKIPPED | This task exercised native audio import and engine transitions; no new physical microphone/paste test was performed. |
| Intel hardware | SKIPPED | Source selects Whisper by default on Intel and rejects an explicit unsupported Parakeet selection; no Intel Mac was available for a live check. |

The active Command Line Tools installation lacked XCTest. Tests passed using the
existing full Xcode installation without changing `xcode-select`:

```sh
DEVELOPER_DIR='/Users/noahwoodward/Downloads/Xcode-beta.app/Contents/Developer' \
LOWKEY_SUPPORT_DIRECTORY="$PWD/dist/engine-memory-review/test-support" \
xcrun swift test --jobs 2
```

The updated installed app's fresh startup physical footprint was 43.3 MiB
(60.9 MiB peak). This point does not establish its footprint after extended
recording or compare equal workloads against the old app. The 467.7 MiB
`Neural Engine (reserved)` region in `vmmap` is unallocated virtual address
space and is not counted as physical memory savings.

## Local delivery

Installed app: `/Users/noahwoodward/Applications/Lowkey.app`

Backup: `/Users/noahwoodward/Library/Application Support/Lowkey Backups/20260907-222633-exclusive-engine`

Installed executable SHA-256:
`a5c4ed4c1efb013a99581b0baa9331f6b4e7da2727a3dbae26cb7589087915db`

Receipts: `dist/engine-memory-review/`, including the build/test logs, before and
after `vmmap` summaries, `installed-verification.json`, the staged app, and copies
of the source files before this change. The development app was closed and its
original settings restored after testing. Existing unrelated working-tree edits
were preserved. No GitHub release was published.
