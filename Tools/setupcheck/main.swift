import EventKit

let cases: [(EKAuthorizationStatus, CalendarSetup)] = [
    (.notDetermined, .request), (.writeOnly, .upgrade), (.denied, .settings),
    (.restricted, .restricted), (.fullAccess, .ready),
]
for (status, expected) in cases {
    let actual = CalendarSetup(authorization: status)
    precondition(actual == expected, "Wrong Calendar recovery for \(status)")
    precondition((actual.menuTitle == nil) == (expected == .ready))
}
// Re-evaluation must reflect changes made outside the app, with no cached denial.
precondition(CalendarSetup(authorization: .denied) != CalendarSetup(authorization: .fullAccess))
print("Calendar setup checks passed (no permission requests)")
