# Dev integration testing

All nine feature PRs are integrated into `dev`; `main` is unchanged. The microphone
PR adds a feasibility report only. Integration resolves overlapping dashboard
checks and camera/lifecycle code while retaining system-overlay connection behavior.
CI now checks pushes to dev and runs setup, recovery and usage checks together.

Before approving dev for main, install build/i7.ipa manually with TrollStore and run
the matching Mac build. Check dashboard widget swipes and empty states, waiting and
welcome layouts, Control Center/Notification Center without a reconnect flash,
Front/Back camera switching and live/error status, USB unplug/replug, phone relock,
and Mac sleep/wake. Check setup guidance with missing integrations or permissions
where practical. Do not delete phone data to test. Real hardware scenarios remain
unverified by the automated checks.

Merge dev into main only after Arnas finishes testing and explicitly approves it.
