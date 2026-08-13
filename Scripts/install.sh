#!/bin/zsh
set -euo pipefail

# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/nhwoodward/Lowkey/main/Scripts/install.sh | zsh
#
# Or from a checkout:
#   ./Scripts/install.sh

REPO="${LOWKEY_REPO:-https://github.com/nhwoodward/Lowkey.git}"
SRC="${LOWKEY_DIR:-$HOME/src/Lowkey}"
SUPPORT="${HOME}/Library/Application Support/Lowkey"
LEGACY="${HOME}/Library/Application Support/Whisperly"
MODEL="${SUPPORT}/models/ggml-small.bin"
MODEL_URL="${LOWKEY_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin}"
MIN_MODEL_BYTES=100000000

info() { print -r -- "==> $*"; }
die() { print -r -- "error: $*" >&2; exit 1; }

if [[ "$(uname -s)" != Darwin ]]; then
    die "Lowkey is macOS only."
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

if [[ -f "${PWD}/Package.swift" && -d "${PWD}/Sources/Lowkey" ]]; then
    SRC="${PWD}"
    info "Using this checkout"
elif [[ -f "${SRC}/Package.swift" && -d "${SRC}/Sources/Lowkey" ]]; then
    info "Updating ${SRC}"
    git -C "${SRC}" pull --ff-only
else
    info "Cloning Lowkey into ${SRC}"
    mkdir -p "$(dirname "${SRC}")"
    git clone "${REPO}" "${SRC}"
fi

if [[ -d "${LEGACY}" && ! -d "${SUPPORT}" ]]; then
    info "Moving Application Support from Whisperly to Lowkey"
    mv "${LEGACY}" "${SUPPORT}"
    rm -rf "${SUPPORT}/signing"
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
    tmp="$(mktemp "${TMPDIR:-/tmp}/lowkey-model.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT
    curl -fL --progress-bar -o "${tmp}" "${MODEL_URL}"
    bytes="$(stat -f %z "${tmp}" 2>/dev/null || echo 0)"
    if (( bytes < MIN_MODEL_BYTES )); then
        die "Model download looks wrong (${bytes} bytes). Try again."
    fi
    mv "${tmp}" "${MODEL}"
    trap - EXIT
fi

info "Building and installing Lowkey.app"
pkill -x Lowkey 2>/dev/null || true
pkill -x Whisperly 2>/dev/null || true
"${SRC}/Scripts/bundle.sh"

open "${HOME}/Applications/Lowkey.app"

print -r -- ""
print -r -- "Lowkey is installed."
print -r -- "Hold Right Command, speak, release."
print -r -- "Grant Microphone and Accessibility when macOS asks."
