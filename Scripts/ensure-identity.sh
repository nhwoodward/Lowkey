#!/bin/zsh
set -euo pipefail

IDENT_NAME="Whisperly Local"
SUPPORT="${HOME}/Library/Application Support/Whisperly/signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENT_NAME}"; then
    exit 0
fi

mkdir -p "${SUPPORT}"
if [ ! -f "${SUPPORT}/whisperly.key" ]; then
    openssl req -new -x509 -days 3650 -nodes \
        -newkey rsa:2048 \
        -subj "/CN=Whisperly Local/O=Whisperly/C=US" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=digitalSignature" \
        -keyout "${SUPPORT}/whisperly.key" \
        -out "${SUPPORT}/whisperly.crt" >/dev/null 2>&1
fi

openssl pkcs12 -export \
    -inkey "${SUPPORT}/whisperly.key" \
    -in "${SUPPORT}/whisperly.crt" \
    -out "${SUPPORT}/whisperly.p12" \
    -passout pass:whisperly \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

security import "${SUPPORT}/whisperly.p12" \
    -k "${KEYCHAIN}" \
    -P whisperly \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A >/dev/null 2>&1 || true

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" \
    "${KEYCHAIN}" >/dev/null 2>&1 || true
