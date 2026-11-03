# Design and behaviour notes

Working notes on how septintas looks and behaves.

## Moving between screens

The current screen stays up until the next one has something to show, or for 5 seconds at most.

| From | To | What happens |
|---|---|---|
| Waiting | Second screen or Standby | 0.48-second impact from the centre, opening out to the corners |
| Waiting | Dashboard | Widgets grow from 90% to 100% scale and fade in over the live gradient (0.9s), then the gradient fades out (1.2s), with widget backgrounds and content colours fading in over its final 0.7s |
| Second screen | Dashboard | The last desktop frame blurs over 0.22s, then the same dashboard entrance plays over that frozen backdrop, which fades away in place of the waiting gradient |
| Dashboard | Second screen | Widget surfaces dissolve as the dashboard shrinks to 95% and fades out (0.3s), then the live desktop underneath comes into focus (0.25s) |
| Any mode | Later mode in menu | Warm gradient sweeps left to right, swaps under full cover, then clears |
| Any mode | Earlier mode in menu | The same gradient sweeps right to left |
| Any mode | Waiting (unplugged) | 1s fade to black, then 2s gradient fade-in; text starts 1s after the gradient |

This all lives in `Phone/RootViewController.swift`. A mode calls `onReady` when it's ready to be seen.

## Design TODO

- [ ] Explore a background behind the dashboard widgets using the existing warm gradient.
- [ ] Compare opaque tiles with semitransparent dark tiles over that background; check text and
  calendar colour readability on the iPhone before choosing the treatment.

Transitions accept readiness once per mode change and cancel stale reveal completions on disconnect.

Second Screen and Dashboard share this transition system. Standby is retained only as a legacy wire value. Rapid requests keep only the latest
requested mode until the active effect finishes. Disconnect cancels the active effect and preserves
its visible frame under the return to waiting. Reduce Motion and unavailable Metal use short fades.
The waiting title reads “Waiting for your Mac” and uses the system Semibold font at 36 points.

On a fresh install, the same waiting field welcomes the user with “Welcome to septintas”
(36pt system Semibold, wrapping in portrait) and “Rotate your iPhone to landscape.” (18pt).
Only this welcome allows portrait. Landscape at launch, rotating to landscape, or a Mac
connection restores the unchanged landscape-only waiting/connected flow. The welcome allows
Auto-Lock and is claimed on its first launch, even if the app is closed before rotation.
Existing installs skip it: the retained data container predates the new executable's build date.
Missing dates also skip it; the decision is then persisted in `firstRunWelcomeSeen`.
`Tools/shadercheck --welcome` renders an iPhone 7 portrait copy/layout approximation with the
real shader (AppKit text metrics); `Tools/welcomecheck` checks launch/migration persistence.

The warm field keeps its flowing pattern, with amber reduced to a small accent and more pink/coral.

While disconnected, the amber stop is pure black. On connection it blends back to amber in 0.25s
before the dashboard entrance or impact reveal. The waiting pattern otherwise stays the same.

The calendar has no standalone date row. Events continue across days with compact day headings.
Calendar content has 14pt insets on every side. Up to four events fit; day headings and the
remaining-events row can reduce capacity. The remaining count applies only to the last visible day.
The Mac sends the next eight events so the phone can fill the available height.

Music gradients use up to three artwork colours, merged within a Lab distance of 25. Groups need
24% coverage; a 3.25× dominant group suppresses runners-up. Colour strength is 68%, diagonally
blended; a single colour fades to a nearby darker shade. Extraction runs off the main thread on an 80px sample.

The usage widget uses Split atmosphere at 20% strength: warm charcoal above, cool charcoal below.

The phone dashboard shifts all widgets together once per minute along a square within ±2pt to
spread static OLED content across pixels. Offsets align to physical pixels, fit within the existing
padding, and reset when the dashboard stops. Shifts only run while the app is active.

Dashboard entrance starts with transparent widget surfaces and white foregrounds. Surfaces and
normal foreground colours fade in during the final 0.7s of the transition field’s 1.2s fade-out. Music without an active track is labelled “Not Playing”.

Music gradient stops are constrained across all colours: pairwise Lab distance ≤18 and luminance
difference ≤0.035, with peak luminance limited by the actual music text colours. This prevents harsh black/white, yellow/black and
opposing-hue jumps while preserving the dominant artwork colour.

The music gradient keeps bright artwork colours and tones them down until white-text contrast is
at least 7:1 and gray secondary-text contrast is at least 4.5:1. No hue is rejected for brightness.

When music pauses or stops, its card fades upward and the calendar fills the right column over
0.65s. Additional events enter with an 8pt staggered lift. When music resumes, the calendar shrinks
and clips excess rows at its lower edge; its count is recomputed after the resize.

Screen Size now offers Default and More Space, persists in a fixed preferences domain and flushes
on selection. Removed Larger Text preferences migrate to Default. Standby is absent from the menu.
