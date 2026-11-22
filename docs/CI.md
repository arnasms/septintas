# CI checks

`.github/workflows/ci.yml` runs on pull requests (including forks) and pushes to
main. It grants only read access to repository contents, does not persist checkout
credentials, and uses no secrets, signing identities, provisioning profiles or
user keychain setup. Do not replace `pull_request` with `pull_request_target` to
execute contributor code.

The job generates Xcode projects, builds both apps with signing disabled, builds
the universal Now Playing helper, and runs `scripts/check.sh`. The check script
runs synthetic palette, calendar and isolated preferences checks, and compiles
the fake-phone tool. It does not launch the fake phone or access a physical phone.
UIKit rendering and Metal GPU checks remain separate from this headless suite.

## Recovery follow-up

After `feat/connection-recovery` is merged, add
`./scripts/check-connection-recovery.sh` to `scripts/check.sh`. Its loopback harness
tests repeated transport close/start, stale deliveries, listener restart and
PhoneLink disconnect/suspend recovery without a phone. It currently depends on
feature APIs such as `PhoneServer.stop()` and `PhoneLink.setSuspended(_:)` that do
not exist on this branch, so importing only the harness would fail compilation.
Keep the feature source changes in their own branch. The harness needs TCP port
27077 free; physical USB and actual sleep/wake remain manual checks.

## Palette dependency

This branch includes palette fixture commit `772351d`. The independent palette
review may revise it; reconcile those changes before merging CI. No additional
palette implementation changes are part of the CI review.
