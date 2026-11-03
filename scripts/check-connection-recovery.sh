#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Shared/Wire.swift Shared/WireConnection.swift Phone/PhoneServer.swift Mac/UsbMux.swift \
    Tools/fakephone/recovery/main.swift -o build/connection-recovery-check
build/connection-recovery-check
