#!/bin/zsh
# Deterministic checks that need neither a phone nor user permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks
swiftc Shared/ArtworkPalette.swift Tools/palettecheck/main.swift -o build/checks/palettecheck
build/checks/palettecheck
swiftc Shared/Dashboard.swift Shared/CalendarLayout.swift Tools/calendarcheck/main.swift -o build/checks/calendarcheck
build/checks/calendarcheck
swiftc Shared/Wire.swift Mac/ScreenPreferences.swift Tools/preferencescheck/main.swift -o build/checks/preferencescheck
suite="com.septintas.check.$RANDOM.$$"
build/checks/preferencescheck "$suite" write
build/checks/preferencescheck "$suite" read
build/checks/preferencescheck "$suite" migrate
swiftc Shared/*.swift Mac/VirtualCamera.swift Tools/fakephone/main.swift -o build/checks/fakephone
# UIKit rendering and Metal GPU checks require a simulator/device or GPU and run separately.

./scripts/check-setup.sh
./scripts/check-connection-recovery.sh
swiftc Shared/Dashboard.swift Mac/LimitsSource.swift Tools/limitscheck/main.swift -o build/checks/limitscheck
build/checks/limitscheck
