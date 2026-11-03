#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Mac/CalendarSetup.swift Tools/setupcheck/main.swift -o build/setupcheck
build/setupcheck
