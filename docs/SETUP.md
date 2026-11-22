# Agent setup instructions

The README's "Set up with an agent" prompt points coding agents here. Work through
the setup until septintas is running or you reach a step that needs the user's input.

Read README.md, docs/DESIGN.md and the build scripts before running anything.
Follow the repository's current instructions and use its existing scripts.

Check the macOS version, Xcode and active developer directory, iPhoneOS SDK,
XcodeGen, ldid, OBS and CodexBar. Explain and install missing dependencies
where possible, asking before paid downloads or replacing existing software.
The tested phone setup is an iPhone 7 on iOS 15.8.6 with TrollStore already
installed. Ask the user to confirm their phone's model, iOS version and TrollStore
availability before trying to install the phone app. If their setup differs,
explain what is untested; do not jailbreak, change iOS or install TrollStore.

Build the Mac app with ./scripts/build-mac.sh and the phone IPA with
./scripts/build-phone.sh. Diagnose build failures and resolve local setup
issues. If the user's setup needs code changes, for example a different iPhone
model, explain what is needed and make the changes only with their agreement.
Launch the built Mac app. Guide the user through any signing/keychain prompts and
required macOS permissions, including Screen Recording, and phone permissions
when prompted. Never disable system security or grant permissions on their behalf.

Help the user install build/i7.ipa with TrollStore; updates are installed the
same way. Have the user connect the phone by USB, trust the Mac if prompted, and
open septintas in the foreground.

Verify the USB connection, Extended Display, Dashboard and webcam as far as
this hardware allows. Walk the user through selecting the OBS virtual camera in a
camera app; quitting that app should turn the webcam off a few seconds later
(the Mac menu can also turn it off). Distinguish
what you actually verified from checks the user still needs to perform on the
devices. Finish with the built app and IPA paths, what works, and any remaining
blocker with the exact next step. Ask for manual actions as they become necessary,
then continue when the user confirms they are done.

## Contributing changes back

If you changed any code along the way (support for another iPhone model, a bug
fix, a new feature), suggest that the user sends the changes back to the project
as a pull request. Fixes for other phone models, general bug fixes and feature
additions are all welcome. If the user doesn't know what a pull request is,
explain it in plain terms: a request to the project owner to review their changes
and add them to the main project, made from their own copy (fork) on GitHub.
Offer to prepare it for them, and only open it once they agree.
