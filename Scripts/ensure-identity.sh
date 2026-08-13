#!/bin/zsh
set -euo pipefail

IDENT_NAME="Lowkey Local"
SUPPORT="${HOME}/Library/Application Support/Lowkey/signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# Do not use find-identity -v. That hides this self-signed cert as
# untrusted and would recreate it on every build.
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENT_NAME}"; then
    exit 0
fi

mkdir -p "${SUPPORT}"
if [ ! -f "${SUPPORT}/lowkey.key" ]; then
    openssl req -new -x509 -days 3650 -nodes \
        -newkey rsa:2048 \
        -subj "/CN=Lowkey Local/O=Lowkey/C=US" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=digitalSignature" \
        -keyout "${SUPPORT}/lowkey.key" \
        -out "${SUPPORT}/lowkey.crt" >/dev/null 2>&1
fi

openssl pkcs12 -export \
    -inkey "${SUPPORT}/lowkey.key" \
    -in "${SUPPORT}/lowkey.crt" \
    -out "${SUPPORT}/lowkey.p12" \
    -passout pass:lowkey \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

security import "${SUPPORT}/lowkey.p12" \
    -k "${KEYCHAIN}" \
    -P lowkey \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null 2>&1 || true

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" \
    "${KEYCHAIN}" >/dev/null 2>&1 || true
