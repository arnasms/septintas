#!/bin/zsh
# Builds the phone app and installs it over the USB cable, through the copy already on the phone.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-phone.sh
swiftc -O -swift-version 5 Tools/pushphone/main.swift Mac/UsbMux.swift Shared/*.swift -o build/pushphone
build/pushphone build/i7.ipa
