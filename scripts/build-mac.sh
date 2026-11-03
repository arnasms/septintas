#!/bin/zsh
# Builds the Mac app and signs it with a local certificate that stays the same between builds.
# Ad-hoc signing would change the app's identity every build, and macOS would forget the Screen
# Recording permission each time. The certificate is only ever used on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

CERT="i7 Companion Local Signing"
if ! security find-certificate -c "$CERT" >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    PASS=$(openssl rand -hex 16)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$CERT" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "keyUsage=critical,digitalSignature" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -passout "pass:$PASS"
    security import "$TMP/cert.p12" -P "$PASS" -T /usr/bin/codesign >/dev/null
    rm -rf "$TMP"
fi

xcodegen generate >/dev/null
xcodebuild -project i7Companion.xcodeproj -scheme i7Mac -configuration Release \
    -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u

APP="build/dd/Build/Products/Release/septintas.app"

# The Now Playing helper is loaded by /usr/bin/perl rather than by the app, so it's built separately.
mkdir -p "$APP/Contents/Resources"
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -framework Foundation \
    Helpers/NowPlaying/now-playing.m -o "$APP/Contents/Resources/now-playing.dylib"
codesign --force --sign "$CERT" "$APP/Contents/Resources/now-playing.dylib"

codesign --force --sign "$CERT" --identifier com.arnasmasalis.i7companion.mac "$APP"
codesign --verify "$APP" && echo "signed $(pwd)/$APP"
