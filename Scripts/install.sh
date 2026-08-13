#!/bin/zsh
set -euo pipefail

# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/nhwoodward/Whisperly/main/Scripts/install.sh | zsh
#
# Or from a checkout:
#   ./Scripts/install.sh

REPO="${WHISPERLY_REPO:-https://github.com/nhwoodward/Whisperly.git}"
SRC="${WHISPERLY_DIR:-$HOME/src/Whisperly}"
SUPPORT="${HOME}/Library/Application Support/Whisperly"
MODEL="${SUPPORT}/models/ggml-small.bin"
MODEL_URL="${WHISPERLY_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin}"
MIN_MODEL_BYTES=100000000

info() { print -r -- "==> $*"; }
die() { print -r -- "error: $*" >&2; exit 1; }

if [[ "$(uname -s)" != Darwin ]]; then
    die "Whisperly is macOS only."
fi

if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required. Install it from https://brew.sh and run this again."
fi

if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    die "Install the Xcode Command Line Tools when macOS asks, then run this again."
fi

if ! command -v whisper-server >/dev/null 2>&1; then
    info "Installing whisper-cpp (local Whisper engine)"
    brew install whisper-cpp
fi

if [[ -f "${PWD}/Package.swift" && -d "${PWD}/Sources/Whisperly" ]]; then
    SRC="${PWD}"
    info "Using this checkout"
elif [[ -f "${SRC}/Package.swift" && -d "${SRC}/Sources/Whisperly" ]]; then
    info "Updating ${SRC}"
    git -C "${SRC}" pull --ff-only
else
    info "Cloning Whisperly into ${SRC}"
    mkdir -p "$(dirname "${SRC}")"
    git clone "${REPO}" "${SRC}"
fi

mkdir -p "${SUPPORT}/models"
chmod 700 "${SUPPORT}" 2>/dev/null || true

need_model=1
if [[ -f "${MODEL}" ]]; then
    bytes="$(stat -f %z "${MODEL}" 2>/dev/null || echo 0)"
    if (( bytes > MIN_MODEL_BYTES )); then
        need_model=0
    fi
fi

if (( need_model )); then
    info "Downloading ggml-small.bin (~466 MB). This happens once."
    tmp="$(mktemp "${TMPDIR:-/tmp}/whisperly-model.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT
    curl -fL --progress-bar -o "${tmp}" "${MODEL_URL}"
    bytes="$(stat -f %z "${tmp}" 2>/dev/null || echo 0)"
    if (( bytes < MIN_MODEL_BYTES )); then
        die "Model download looks wrong (${bytes} bytes). Try again."
    fi
    mv "${tmp}" "${MODEL}"
    trap - EXIT
fi

info "Building and installing Whisperly.app"
pkill -x Whisperly 2>/dev/null || true
"${SRC}/Scripts/bundle.sh"

open "${HOME}/Applications/Whisperly.app"

print -r -- ""
print -r -- "Whisperly is installed."
print -r -- "Hold Right Command, speak, release."
print -r -- "Grant Microphone and Accessibility when macOS asks."
