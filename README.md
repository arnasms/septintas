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

## Testing without the phone

`Tools/fakephone` stands in for the iPhone on the Mac. Start it, then open the Mac app with `I7_DIRECT_PORT=27077` to connect to it instead of USB. `I7_TEST_CAMERA=1` also starts the webcam straight away.

`Tools/dashcheck` draws the phone's real dashboard to a PNG, and `Tools/shadercheck` renders the waiting screen and transitions frame by frame. Live mode swaps still need checking on the phone.
