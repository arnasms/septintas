#!/bin/zsh
# Builds build/i7.ipa for the iPhone. Uses the iOS compiler directly, so it doesn't need Xcode's
# separate iOS platform download. The app is fakesigned, which is what TrollStore expects.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/Payload/septintas.app
rm -rf build/Payload build/i7.ipa
mkdir -p "$OUT"

# WELCOME_PREVIEW=1 makes a test build that welcomes on every launch.
SWIFT_FLAGS=()
if [[ "${WELCOME_PREVIEW:-0}" == "1" ]]; then
    SWIFT_FLAGS+=(-D WELCOME_PREVIEW)
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -O -parse-as-library \
    -sdk "$SDK" -target arm64-apple-ios15.0 -swift-version 5 \
    -module-name i7 "${SWIFT_FLAGS[@]}" \
    Phone/*.swift Shared/*.swift \
    -o "$OUT/septintas"

sed -e 's/$(EXECUTABLE_NAME)/septintas/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.arnasmasalis.i7companion.phone/' \
    -e 's/$(PRODUCT_NAME)/septintas/' \
    -e 's/$(MARKETING_VERSION)/1.0/' \
    -e 's/$(CURRENT_PROJECT_VERSION)/1/' \
    Phone/Info.plist > "$OUT/Info.plist"
plutil -insert MinimumOSVersion -string 15.0 "$OUT/Info.plist"
plutil -insert UIDeviceFamily -json '[1]' "$OUT/Info.plist"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$OUT/Info.plist"
plutil -insert DTPlatformName -string iphoneos "$OUT/Info.plist"
plutil -convert binary1 "$OUT/Info.plist"
printf 'APPL????' > "$OUT/PkgInfo"

cp Phone/Assets.xcassets/AppIcon.appiconset/AppIcon60x60@*.png "$OUT/"

ldid -S "$OUT/septintas"
(cd build && zip -qr i7.ipa Payload)
echo "built $(pwd)/build/i7.ipa"
