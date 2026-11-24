#!/bin/bash
# Guided Developer ID setup, from Terminal (docs/APPLE-DEVELOPER.md). Run it again after each browser
# step: it checks what's already done, does the next thing it can, and says what's left.
#
#   1. Certificate: makes a private key and a certificate signing request (CSR) for you to upload
#      at developer.apple.com, then imports the certificate you download into the login keychain.
#   2. Team ID: read from the certificate, saved in project.yml for `make release`.
#   3. Notarization: saves a notarytool profile named "mactivity" in the keychain.
#   4. Sparkle: makes the update-signing key in the keychain and puts its public half in project.yml.
#
# Nothing secret is written to the repo. The private key and CSR live in ~/.config/mactivity-signing.
# Set CER=/path/to/file.cer if the downloaded certificate isn't in ~/Downloads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${MACTIVITY_SIGNING_DIR:-$HOME/.config/mactivity-signing}"
KEY="$DIR/developer-id.key.pem"
CSR="$DIR/Mactivity.certSigningRequest"
P12="$DIR/developer-id.p12"
PROFILE="${NOTARY_PROFILE:-mactivity}"
OPENSSL=/usr/bin/openssl # LibreSSL: its .p12 files import into the keychain (OpenSSL 3's need -legacy)
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_PAGE="https://developer.apple.com/account/resources/certificates/add"
PASSWORD_PAGE="https://account.apple.com/account/manage/section/security"
G2_CA_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
SPARKLE_BIN="$ROOT/build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Mactivity's own update key, apart from any other app's: a leak or a sale touches only this app.
SPARKLE_ACCOUNT="mactivity"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
todo() { printf '  → %s\n' "$*"; }

identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true
}

set_setting() { # set_setting KEY VALUE: replaces `KEY: "..."` in project.yml
  /usr/bin/sed -i '' -E "s|^([[:space:]]*$1:) \"[^\"]*\"|\\1 \"$2\"|" "$ROOT/project.yml"
}

get_setting() {
  /usr/bin/sed -nE "s|^[[:space:]]*$1: \"([^\"]*)\".*|\\1|p" "$ROOT/project.yml" | head -1
}

# MARK: 0. Tools

bold "0. Tools"
xcrun notarytool --version >/dev/null 2>&1 || { todo "Install Xcode from the Mac App Store, open it once, then run this again."; exit 1; }
ok "Xcode $(xcodebuild -version | head -1 | awk '{print $2}') with notarytool"

# MARK: 1. Certificate

bold "1. Developer ID Application certificate"
mkdir -p "$DIR"
chmod 700 "$DIR"
NAME="$(identity)"
if [[ -z "$NAME" ]]; then
  CER="${CER:-$(ls -t "$HOME"/Downloads/developerID_application*.cer 2>/dev/null | head -1 || true)}"

  if [[ ! -f "$KEY" ]]; then
    "$OPENSSL" genrsa -out "$KEY" 2048 2>/dev/null
    chmod 600 "$KEY"
    "$OPENSSL" req -new -key "$KEY" -out "$CSR" -subj "/CN=Mactivity Developer ID/C=US"
    ok "Made a private key and a certificate signing request in $DIR"
    CER="" # a certificate downloaded before this key can't match it
  fi

  if [[ -z "$CER" || ! -f "$CER" ]]; then
    todo "Upload the request to Apple (the page and the file open now):"
    echo "       1. Choose \"Developer ID Application\", then Continue."
    echo "       2. Profile Type: \"G2 Sub-CA (Xcode 11.4.1 or later)\"."
    echo "       3. Choose File → $CSR"
    echo "       4. Continue, then Download. It saves developerID_application.cer to Downloads."
    echo "     Then run: make apple-setup"
    open "$CERT_PAGE"
    open -R "$CSR"
    exit 0
  fi

  echo "  Importing $CER"
  PEM="$DIR/developer-id.cer.pem"
  "$OPENSSL" x509 -inform DER -in "$CER" -out "$PEM" 2>/dev/null || "$OPENSSL" x509 -in "$CER" -out "$PEM"
  if [[ "$("$OPENSSL" x509 -noout -pubkey -in "$PEM")" != "$("$OPENSSL" pkey -pubout -in "$KEY" 2>/dev/null)" ]]; then
    todo "$CER wasn't made from this Mac's request ($CSR)."
    echo "     Download the certificate you made from that file, or set CER=/path/to/the.cer."
    exit 1
  fi
  SUBJECT="$("$OPENSSL" x509 -noout -subject -in "$PEM")"
  [[ "$SUBJECT" == *"Developer ID Application"* ]] || { todo "That's not a Developer ID Application certificate: $SUBJECT"; exit 1; }

  # The intermediate that vouches for Developer ID certificates. Without it the identity shows as
  # untrusted. Xcode usually has it already; importing it again is harmless.
  curl -fsSL "$G2_CA_URL" -o "$DIR/DeveloperIDG2CA.cer"
  security import "$DIR/DeveloperIDG2CA.cer" -k "$KEYCHAIN" >/dev/null 2>&1 || true

  echo "  Choose a password for the backup file (developer-id.p12). Keep it in your password manager."
  while true; do
    read -r -s -p "  Password: " PASS
    echo
    read -r -s -p "  Again: " PASS2
    echo
    [[ -n "$PASS" && "$PASS" == "$PASS2" ]] && break
    echo "  They didn't match, or it was empty. Try again."
  done
  "$OPENSSL" pkcs12 -export -inkey "$KEY" -in "$PEM" -name "Developer ID Application" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -out "$P12" -passout "pass:$PASS"
  chmod 600 "$P12"
  security import "$P12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
  unset PASS PASS2

  NAME="$(identity)"
  [[ -n "$NAME" ]] || { todo "Imported, but codesign can't see a valid identity. Check Keychain Access → login → My Certificates."; exit 1; }
  rm -f "$KEY" "$PEM"
  ok "Imported. The unencrypted key file is gone; the key is in your login keychain."
  todo "Back up $P12 and its password in your password manager. It's the only copy of the key outside this Mac."
fi
ok "$NAME"
TEAM="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$NAME")"

# MARK: 2. Team ID

bold "2. Team ID"
if [[ "$(get_setting MACTIVITY_RELEASE_TEAM)" != "$TEAM" ]]; then
  set_setting MACTIVITY_RELEASE_TEAM "$TEAM"
  ok "Saved $TEAM in project.yml (MACTIVITY_RELEASE_TEAM). make release uses it."
else
  ok "$TEAM (in project.yml)"
fi

# MARK: 3. Notarization

bold "3. Notarization profile \"$PROFILE\""
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "Saved in the keychain and accepted by Apple"
else
  todo "Make an app-specific password (the page opens now):"
  echo "       Sign-In and Security → App-Specific Passwords → +, name it \"notarytool\", copy it."
  open "$PASSWORD_PAGE"
  read -r -p "  Your Apple ID email: " APPLE_ID
  echo "  notarytool asks for the app-specific password next and checks it with Apple."
  xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM"
  ok "Saved"
fi

# MARK: 4. Sparkle

bold "4. Sparkle update key"
if [[ -n "$(get_setting SUPublicEDKey)" ]]; then
  ok "Public key is in project.yml"
else
  if [[ ! -x "$SPARKLE_BIN/generate_keys" ]]; then
    echo "  Fetching Sparkle's tools (a one-time build)…"
    make -C "$ROOT" build >/dev/null
  fi
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" >/dev/null # makes the key in the keychain if there isn't one; never replaces it
  PUBLIC="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
  set_setting SUPublicEDKey "$PUBLIC"
  ok "Made the update-signing key in your keychain and put its public half in project.yml"
fi
# A one-time backup copy of the private key, for a password manager. The marker stops it being exported again.
if [[ ! -f "$DIR/sparkle-key-exported" ]]; then
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$DIR/sparkle-private-key.txt"
  chmod 600 "$DIR/sparkle-private-key.txt"
  touch "$DIR/sparkle-key-exported"
  todo "Back up $DIR/sparkle-private-key.txt in your password manager, then delete the file."
  echo "     Lose this key and existing installs can't take updates from you."
fi

bold "Ready. Build the signed, notarized DMG with:  make release"
