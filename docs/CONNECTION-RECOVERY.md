# Connection recovery

Run `scripts/check-connection-recovery.sh` without a phone. This compiles the actual
WireConnection, PhoneServer and PhoneLink with a loopback harness under
Tools/fakephone/recovery. It requires no screen, camera or calendar permission.
The port 27077 must be free. Failures exit nonzero; no permission results are mocked.

Checks cover 100 repeated transport starts/closes (including close before start),
exactly-once close, descriptor release, rejected sends and queued stale commands;
20 listener stop/restart cycles with stale accept rejection; and real TCP peer
loss/reconnect plus PhoneLink suspend/wake invalidation and reconnection.

Wire messages now arrive on the main queue, serializing mode and decoder lifecycle
with disconnect, relock and sleep. A closed transport discards queued deliveries.
Phone listener generations reject accepts queued before resign-active; its accept
thread owns descriptor closure and stop waits for port release before restart.
Camera encoders retain their original connection destination; decoder completions
are generation-checked after reset. Mac sleep tears down the connection and mode,
then wake reconnects and reapplies the saved mode and sleep-prevention preference.
Screen capture rechecks its generation after asynchronous discovery/start and stops
a stream that finished starting after teardown; stale stream errors cannot restart it.
USB detach invalidates pending connection attempts and tears down the active peer;
usbmux Connect handshakes have bounded IO waits.

## Manual scenarios still unverified

- Physical USB unplug/replug during dashboard, second display, transition and webcam.
- Actual macOS sleep/wake, usbmuxd restart, multiple attached phones and long sleep.
- Phone lock/unlock, app background/foreground and rapid relock during reconnect.
- Camera permission denial/grant, Screen Recording permission and OBS camera use.
- First frame/keyframe timing, landscape presentation, Auto-Lock and performance
  under sustained video load (message delivery now shares the main queue).

Install build/i7.ipa manually with TrollStore. No phone installation, remote launch,
permission test or phone data deletion is part of the automated checks.

## Foreground system overlays

Control Center and Notification Center temporarily make the app inactive. That pauses
waiting-screen animation and disables idle prevention, but keeps the USB connection
and current mode. Only `applicationDidEnterBackground` tears down the session (app
switching or locking). Becoming active restarts animation and idle prevention; the
listener start is idempotent, so an existing session is retained.

Manual device checks still required: open/close both centers repeatedly while showing
the dashboard and second screen; confirm no waiting transition. Repeat during webcam
capture (iOS may interrupt capture independently), then lock/unlock and switch apps to
confirm actual background teardown and reconnect still work.
