# septintas

Turns an old iPhone into a screen and a webcam for your Mac, at the same time, over the USB cable.

The name is Lithuanian for "seventh", after the iPhone 7 it was built on.

<!-- Demo video and screenshots go here. -->

## Why it exists

iOS only lets the foreground app use the camera, so running a webcam app like Camo means the phone can't also show anything useful. septintas is one app that does both jobs.

## What it does

- **Extended Display:** the iPhone becomes an extended display for the Mac. The display exists only while the mode is on, so windows return to your other screens when it stops.
- **Dashboard:** Claude and Codex usage limits and cost, what's playing, and your next calendar events.
- **Webcam:** the front camera can be used on the Mac for Zoom, Meet and the like. It runs underneath whichever mode is on screen.

## Before you try it

This is a personal project. I use it with TrollStore on my iPhone 7 and my Mac, and that's the only setup it has been tested on. You'll need:

- An iPhone 7 on iOS 15.8.6 with [TrollStore](https://github.com/opa334/TrollStore) installed. The phone app isn't on the App Store and is fakesigned for TrollStore.
- A Mac on macOS 14 or later, with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- [OBS](https://obsproject.com) installed for the webcam. OBS itself can stay closed.
- [CodexBar](https://github.com/steipete/CodexBar) installed for the dashboard's usage numbers. It doesn't need to be running.

## Set up with an agent

Copy this prompt into a coding agent on your Mac that can run terminal commands. It will handle the setup it can automate and walk you through the steps that need your phone or a system permission.

```text
Set up septintas on my Mac and iPhone, working through the setup until it is
running or you reach a step that needs my input.

Use https://github.com/arnasms/septintas. If we are already in its checkout,
use it and preserve any existing changes; otherwise clone it. Read README.md,
docs/DESIGN.md and the build scripts before running anything. Follow the
repository's current instructions and use its existing scripts.

Check my macOS version, Xcode and active developer directory, iPhoneOS SDK,
XcodeGen, ldid, OBS and CodexBar. Explain and install missing dependencies
where possible, asking before paid downloads or replacing existing software.
The tested phone setup is an iPhone 7 on iOS 15.8.6 with TrollStore already
installed. Ask me to confirm my phone's model, iOS version and TrollStore
availability before trying to install the phone app. If my setup differs,
explain what is untested; do not jailbreak, change iOS or install TrollStore.

Build the Mac app with ./scripts/build-mac.sh and the phone IPA with
./scripts/build-phone.sh. Diagnose build failures and resolve local setup
issues; do not rewrite app code just to bypass an unsupported environment.
Launch the built Mac app. Guide me through any signing/keychain prompts and
required macOS permissions, including Screen Recording, and phone permissions
when prompted. Never disable system security or grant permissions on my behalf.

Help me install build/i7.ipa with TrollStore for the first installation.
./scripts/push-phone.sh is only for updates when septintas is already running
on the phone and TrollStore's URL Scheme Enabled setting is on. Have me connect
the phone by USB, trust the Mac if prompted, and open septintas in the foreground.

Verify the USB connection, Extended Display, Dashboard and webcam as far as
this hardware allows. Walk me through selecting the OBS virtual camera in a
camera app and turning the webcam off from the Mac menu afterwards. Distinguish
what you actually verified from checks I still need to perform on the devices.
Finish with the built app and IPA paths, what works, and any remaining blocker
with the exact next step. Ask for manual actions as they become necessary,
then continue when I confirm they are done.
```

## Ways you can help out

### Pull requests
This project has only been tested on my personal iPhone 7 and Mac with Sequoia and my specific machine setup (OBS + CodexBar). 
Very appreciated PRs would be:
- making the layout work on other iPhones
- making the Mac companion app more independent from OBS and CodexBar

I'm happy with the functionality as is, but widgets are modular, so you can add your own.

### Donations
Would go towards an Apple Developer Account and would let the project 1) not require workarounds with signing 2) have its own webcam profile independent of OBS 3) maybe even see the light of day on the App Store

## How it works

```
Mac menu bar app (Mac/)                          iPhone app (Phone/)
  Virtual display -> screen capture -> H.264  ---USB-->  decoder -> full-screen view
  OBS Virtual Camera <- decoder               <--USB---  H.264 <- front camera
```

- **USB link:** the phone listens on a port, and the Mac reaches it through usbmuxd. No Wi-Fi involved.
- **Webcam on/off:** it turns on the moment an app opens the camera. macOS only reports "in use", and our own feed counts as use, so the Mac can't tell when that app closes it. Turn it off from the menu; it also stops when the Mac sleeps.
- **Dashboard data:** the Mac gathers it in `Mac/DashboardMode.swift` and sends only what changed. The phone saves the last limits and calendar, so the mode can appear before fresh numbers arrive.
- **Now Playing:** runs `Helpers/NowPlaying` inside `/usr/bin/perl`, because macOS gives plain apps nothing.

Transitions, colour rules and other behaviour details are in [docs/DESIGN.md](docs/DESIGN.md).

## Building

```bash
./scripts/build-mac.sh
```

Builds the Mac app and signs it with a local certificate, so macOS keeps the Screen Recording permission between builds.

```bash
./scripts/build-phone.sh
```

Makes `build/i7.ipa`, without needing Xcode's iOS platform download. Install it with TrollStore.

```bash
./scripts/push-phone.sh
```

Builds the phone app and installs it over the cable, through the copy already on the phone. This needs **URL Scheme Enabled** on in TrollStore's settings. TrollStore stays in front afterwards, so reopen the app by hand.

## Automating iPhone sleep prevention

Other Mac apps, Shortcuts and scheduled jobs can call:

```bash
open 'septintas://sleep-prevention/off'  # Allow iPhone Auto-Lock
```

```bash
open 'septintas://sleep-prevention/on'   # Keep the iPhone awake
```

The built Mac app has to be registered with Launch Services first. The companion starts if necessary, and the choice persists across launches, so commands also work while the phone is disconnected.

`off` lets iOS use its configured Auto-Lock delay; it doesn't lock the phone immediately. Once the phone is locked, unlock it and bring septintas to the foreground to reconnect. The "Waiting for your Mac" screen always allows Auto-Lock.

## Adding a mode

A mode is anything the phone's screen shows. The connection, webcam and always-on screen keep running underneath.

1. Add a case to `ModeID` in `Shared/Wire.swift`, with its menu title.
2. Add a `PhoneMode` in `Phone/Modes.swift`: a view, what to do with data from the Mac, and a call to `onReady` once it has something to show.
3. Add a `MacMode` in `Mac/Modes.swift`: gathers the data and sends it with `send`.

The compiler flags the two `switch` statements to fill in (`makePhoneMode`, `makeMacMode`), and the menu lists the new mode by itself. Data travels as `MessageType.modeData`; the format is up to the mode.

## Adding a dashboard widget

The dashboard has two equal slots, controlled on the phone. Swipe up for the next widget or down
for the previous one. Both slots use the same circular list: Usage, Calendar and music, Clock.
Each slot remembers its choice across app launches and reconnects. Duplicates are allowed; changing
one slot never changes the other. Calendar and its expanding/collapsing music card stay together.
Clock uses the phone's local time and date, without any Mac data.

1. Add a self-contained `DashboardWidget` in `Phone/` (see `ClockDashboardWidget` in
   `Phone/DashboardWidgets.swift`). Return its view, lay out within its bounds, implement
   `setWidgetBackgroundAlpha` for the entrance/exit, and optionally implement `tick()` and
   `apply(_:)`. The dashboard handles foreground colour transitions and the shared pixel shift.
2. Register a factory in `dashboardWidgets` at the end of `Phone/DashboardMode.swift`. Give it a
   unique, stable ID, an accessibility title and a position in the swipe order. Factories must create
   independent instances because both slots can show the same widget. Keep registered IDs stable
   to preserve saved choices; removed IDs fall back to the slot's default.
3. If it needs new Mac data, add optional fields to `DashboardUpdate` in `Shared/Dashboard.swift`
   and gather/send them from `Mac/DashboardMode.swift`. No Mac controls are needed.
4. Add a `previewWidgets` case to `Tools/dashcheck/main.swift` and run
   `./scripts/check-dashboard.sh`. Check actual swipes on the phone too.

Widgets are retained and updated in each slot so adjacent pages are ready before a drag begins.
Only the current page and its two neighbours are attached as visible pages. Mac sources continue
running while Dashboard is active, including for widgets currently off screen. This keeps swipes
instant and data fresh, and avoids restarting the usage CLI/calendar/helper on every swipe. The
existing polling intervals and stop-on-mode-exit behaviour are unchanged.

## Testing without the phone

`Tools/fakephone` stands in for the iPhone on the Mac. Start it, then open the Mac app with `I7_DIRECT_PORT=27077` to connect to it instead of USB. `I7_TEST_CAMERA=1` also starts the webcam straight away.

`Tools/dashcheck` draws the phone's real dashboard to a PNG, and `Tools/shadercheck` renders the waiting screen and transitions frame by frame. Run `./scripts/check-dashboard.sh` to render the dashboard variants and check calendar capacity.
Live mode swaps and widget swipes still need checking on the phone.

### Phone webcam controls

While connected, the phone shows a safe-area camera selector (Front / Back) and webcam status above every display mode. Selection lasts for the current app session and does not turn the webcam on; the Mac still controls webcam demand. Switching cameras or landscape orientation restarts capture and H.264 with a fresh keyframe, without changing the wire protocol.

“Webcam live” means encoded camera frames are being accepted by the active connection's send queue. It does not confirm that a Mac application has displayed them. Missing frames clear the live status and show an error after three seconds. Camera interruption, permission denial, and encoder startup failures show errors; turn webcam off and on from the Mac to retry. Backgrounding or disconnecting clears the indicator and stops capture.

Device validation checklist: switch Front/Back repeatedly while a Mac camera client is open; rotate between landscape orientations; unplug during switching; background and reconnect; deny camera permission; interrupt capture with another camera user. Confirm the first picture after each switch decodes, the selected lens matches the picture, and no live indicator survives disconnect/background. These require physical-device testing.
