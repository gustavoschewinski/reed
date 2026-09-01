#!/bin/bash
# Creates a local self-signed code-signing certificate ("Reed Dev Signing")
# and trusts it, so the app keeps its permission grants across rebuilds.
# Run once: bash Scripts/dev-cert.sh
set -euo pipefail

if security find-identity -v -p codesigning | grep -q "Reed Dev Signing"; then
  echo "Certificate already installed."
  exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=Reed Dev Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -legacy -out "$DIR/cert.p12" -inkey "$DIR/key.pem" \
  -in "$DIR/cert.pem" -passout pass:reedtemp -name "Reed Dev Signing"

security import "$DIR/cert.p12" -k ~/Library/Keychains/login.keychain-db \
  -P reedtemp -T /usr/bin/codesign

# May ask for your login password once.
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db "$DIR/cert.pem"

echo "Done. Verify with: security find-identity -v -p codesigning"
