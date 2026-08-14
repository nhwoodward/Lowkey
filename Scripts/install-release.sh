#!/bin/zsh
set -euo pipefail

# Install the latest prebuilt release without cloning or compiling Swift.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nhwoodward/Lowkey/main/Scripts/install-release.sh | zsh

REPO="${LOWKEY_REPO:-nhwoodward/Lowkey}"
SUPPORT="${HOME}/Library/Application Support/Lowkey"
MODEL="${SUPPORT}/models/ggml-small.bin"
MODEL_URL="${LOWKEY_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin}"
APP_URL="${LOWKEY_APP_URL:-https://github.com/${REPO}/releases/latest/download/Lowkey-$(uname -m).zip}"
MIN_MODEL_BYTES=100000000

info() { print -r -- "==> $*"; }
die() { print -r -- "error: $*" >&2; exit 1; }

if [[ "$(uname -s)" != Darwin ]]; then
    die "Lowkey is macOS only."
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) die "Unsupported Mac architecture: ${ARCH}" ;;
esac

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lowkey-install.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
ZIP="${TMP}/Lowkey-${ARCH}.zip"

info "Downloading the latest Lowkey release"
if ! curl -fL --progress-bar -o "$ZIP" "$APP_URL"; then
    die "Could not download ${APP_URL}. Publish a GitHub release first, or set LOWKEY_APP_URL to a release asset."
fi

ditto -x -k "$ZIP" "$TMP"
APP="${TMP}/Lowkey.app"
[[ -d "$APP" ]] || die "The release archive did not contain Lowkey.app."

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
    model_tmp="$(mktemp "${TMP}/lowkey-model.XXXXXX")"
    curl -fL --progress-bar -o "$model_tmp" "$MODEL_URL"
    bytes="$(stat -f %z "$model_tmp" 2>/dev/null || echo 0)"
    if (( bytes < MIN_MODEL_BYTES )); then
        die "Model download looks wrong (${bytes} bytes). Try again."
    fi
    mv "$model_tmp" "$MODEL"
fi

info "Installing Lowkey.app"
pkill -x Lowkey 2>/dev/null || true
mkdir -p "${HOME}/Applications"
rm -rf "${HOME}/Applications/Lowkey.app"
cp -R "$APP" "${HOME}/Applications/Lowkey.app"
open "${HOME}/Applications/Lowkey.app"

print -r -- ""
print -r -- "Lowkey is installed."
print -r -- "Hold Right Command, speak, release."
print -r -- "Grant Microphone and Accessibility when macOS asks."
