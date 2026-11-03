#!/bin/zsh
# Render the real UIKit dashboard via Mac Catalyst, then check shared calendar capacity.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/widget-check
SDK=$(xcrun --sdk macosx --show-sdk-path)
PHONE_SOURCES=(Phone/*.swift)
PHONE_SOURCES=(${PHONE_SOURCES:#Phone/AppDelegate.swift})
xcrun swiftc -O -target arm64-apple-ios15.0-macabi -sdk "$SDK" \
    -F "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -L "$SDK/System/iOSSupport/usr/lib" -swift-version 5 \
    "${PHONE_SOURCES[@]}" Shared/*.swift Tools/dashcheck/main.swift -o build/dashcheck
build/dashcheck build/widget-check/dashboard
swiftc Shared/Dashboard.swift Shared/CalendarLayout.swift Tools/calendarcheck/main.swift -o build/calendarcheck
build/calendarcheck
swiftc Shared/Dashboard.swift Mac/LimitsSource.swift Tools/limitscheck/main.swift -o build/limitscheck
build/limitscheck
