#!/bin/bash
# Creates a stable local code-signing identity, so Remit stops losing its Reminders permission
# every time you rebuild.
#
# Why this is needed: macOS ties a TCC grant (Reminders access) to the app's *code identity*. An
# ad-hoc signature has no identity beyond the hash of the binary itself, so every code change
# produces a different identity and the grant is silently revoked -- you get the "Connect Apple
# Reminders" screen again after every ./run.sh.
#
# A self-signed certificate fixes that: the signature is then anchored to the certificate rather
# than to the binary's hash, so the identity survives rebuilds. This is NOT the same as a paid
# Developer ID -- it does nothing for Gatekeeper or for distributing the app to anyone else. It
# only stabilises the identity on this machine, which is exactly the dev-loop problem.
#
# Run once:   ./setup-signing.sh
# Undo:       security delete-certificate -c "Remit Development" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="Remit Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "'$NAME' already exists in your login keychain. Nothing to do."
    echo "To start over: security delete-certificate -c \"$NAME\" \"$KEYCHAIN\""
    exit 0
fi

echo "==> Generating a self-signed code-signing certificate"
# codeSigning EKU is what makes codesign accept the identity at all; without it the cert imports
# fine and then silently isn't a valid signing identity.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# A real password and -des3 on purpose. macOS's Security framework rejects a PKCS#12 built with
# an empty password ("MAC verification failed"), and the system openssl here is LibreSSL, which
# has no -legacy flag to fall back on.
openssl pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:remit -des3 2>/dev/null

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign grants codesign access to the private key. macOS may still ask once, on the
# first signature, to confirm; choose "Always Allow" and it will not ask again.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P remit -T /usr/bin/codesign

echo
echo "Done. Verify with:"
echo "    security find-identity -p codesigning        # note: no -v"
echo
echo "The certificate reports CSSMERR_TP_NOT_TRUSTED, which is expected and harmless here: it is"
echo "self-signed, so it is not trusted for *distribution*. codesign still signs with it happily,"
echo "and a stable identity is the whole point. This is why -v (valid/trusted only) hides it."
echo
echo "Then rebuild once:"
echo "    ./run.sh"
echo
echo "macOS will ask for Reminders access one final time, and for permission to use the signing"
echo "key (choose \"Always Allow\"). After that the grant survives rebuilds."
echo
echo "Note: this does nothing for distributing the app to other machines -- a downloaded copy"
echo "still needs a paid Developer ID and notarization. See CONTRIBUTING.md."
