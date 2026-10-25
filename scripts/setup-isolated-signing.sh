#!/bin/bash
# Creates a self-signed code-signing identity in a dedicated keychain.
# Unlike setup-local-signing.sh, it never touches the login keychain or its
# trust settings (no password dialog). The certificate stays untrusted, which
# codesign accepts; the designated requirement pins the certificate hash, so
# Camera/Screen Recording approval survives rebuilds.
set -euo pipefail
name="QuietGlass Local Development (isolated)"
dir="$HOME/Library/Application Support/QuietGlassSigning"
keychain="$dir/signing.keychain-db"
mkdir -p "$dir"; umask 077
if [[ -f "$keychain" ]]; then printf '%s\n' "Signing keychain already exists: $keychain"; exit 0; fi
[[ -f "$dir/pw" ]] || /usr/bin/openssl rand -hex 24 > "$dir/pw"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = ext
prompt = no
[subject]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:import
security create-keychain -p "$(cat "$dir/pw")" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$(cat "$dir/pw")" "$keychain"
security import "$tmp/id.p12" -k "$keychain" -P import -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$dir/pw")" "$keychain" >/dev/null
security find-identity -p codesigning "$keychain"
