#!/bin/bash
# Makes Corkscrew's self-signed code-signing certificate and its private key, once, on the
# maintainer's Mac. Release builds signed with it keep one designated requirement (bundle identifier
# + this certificate), so macOS keeps the permissions users gave Corkscrew (files, notifications…)
# across updates. Ad hoc builds get a new one each build. No Apple Developer Program needed; it
# doesn't replace notarization ("Open Anyway" stays).
# Writes <folder>/corkscrew-signing.p12 and <folder>/corkscrew-signing.password (only you can read
# them), then says how to put them into the repository's GitHub Actions secrets. Never commit them.
# Keep a backup: a new certificate means one more permission prompt for every user.
# Usage: make-signing-cert.sh [folder]   (default ~/.corkscrew-signing)
set -euo pipefail
DIR=${1:-$HOME/.corkscrew-signing}
P12="$DIR/corkscrew-signing.p12"
PASSWORD="$DIR/corkscrew-signing.password"
[[ ! -e $P12 ]] || { echo "$P12 is there already. Keep it: a new certificate resets users' permissions." >&2; exit 1; }

umask 077
mkdir -p "$DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# macOS's LibreSSL: its .p12 (3DES) is one that `security import` reads on every macOS version.
OPENSSL=/usr/bin/openssl
cat >"$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Corkscrew Code Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# 30 years: the certificate is in every release's designated requirement, so it must never change.
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -sha256 -days 10950 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" rand -base64 32 | tr -d '\n' >"$PASSWORD"
"$OPENSSL" pkcs12 -export -name "Corkscrew Code Signing" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "file:$PASSWORD" -out "$P12"

echo "Made $P12 and $PASSWORD."
# Public: the designated requirement's "certificate leaf". The release workflow checks it.
SHA1=$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
echo "Certificate SHA-1: $SHA1"
cat <<EOF

Put them into the repository's Actions secrets (gh reads the values from stdin, so they aren't shown),
and the SHA-1 into an Actions variable:

  base64 -i "$P12" | gh secret set CORKSCREW_SIGNING_P12 --repo Prateek-Srivastav/corkscrew
  gh secret set CORKSCREW_SIGNING_PASSWORD --repo Prateek-Srivastav/corkscrew <"$PASSWORD"
  gh variable set CORKSCREW_SIGNING_SHA1 --repo Prateek-Srivastav/corkscrew --body $SHA1

To sign a local scripts/make-dmg.sh build with it:

  CORKSCREW_SIGNING_P12=\$(base64 -i "$P12") CORKSCREW_SIGNING_PASSWORD=\$(cat "$PASSWORD") scripts/make-dmg.sh

Keep a backup of both files somewhere safe (a password manager), outside the repository.
EOF
