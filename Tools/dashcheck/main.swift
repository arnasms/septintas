import UIKit

// Draws the real phone dashboard to PNGs on the Mac, at the iPhone 7's size, using sample numbers,
// so the layout can be checked without installing on the phone. Writes the full calendar to
// <output>.png, then one event to <output>-one.png and an empty calendar to <output>-empty.png.
//
// Usage: dashcheck <output>

let mode = DashboardPhoneMode()
let view = mode.view
view.frame = CGRect(x: 0, y: 0, width: 667, height: 375)
mode.start { _ in }
mode.previewWidgets(["usage", "calendar"])

func render(_ update: DashboardUpdate, to path: String) {
    mode.receive(try! JSONEncoder().encode(update))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
        view.layer.render(in: context.cgContext)
    }
    try! image.pngData()!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func tomorrow(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date().addingTimeInterval(24 * 3600))!
}

let output = CommandLine.arguments[1]
let soon = Date().addingTimeInterval(2 * 3600)
let later = Date().addingTimeInterval(4 * 24 * 3600)
let navy = CalendarColor(red: 0.024, green: 0.098, blue: 0.31)
let red = CalendarColor(red: 1, green: 0.27, blue: 0.23)
let lecture = CalendarEvent(title: "Cloud City Design Workshop", start: tomorrow(12, 40), end: tomorrow(14, 10), color: navy)
let lesson = CalendarEvent(title: "Moon Garden Planning", start: tomorrow(13, 0), end: tomorrow(14, 0), color: red)

render(DashboardUpdate(
    limits: [
        ProviderLimits(provider: .claude, sessionPercent: 47, sessionResets: soon, weekPercent: 10, weekResets: later, costToday: 17.98, costMonth: 26.79, outOfDate: false),
        ProviderLimits(provider: .codex, sessionPercent: 12, sessionResets: soon, weekPercent: 63, weekResets: later, costToday: 4.2, costMonth: 118.5, outOfDate: true),
    ],
    track: TrackInfo(title: "A Song With Quite A Long Title Indeed", artist: "Some Artist", duration: 200, elapsed: 80, isPlaying: true, hasTrack: true),
    calendar: CalendarStatus(events: [lecture, lesson], moreCount: 3, moreColors: [navy], accessDenied: false)),
    to: output + ".png")
render(DashboardUpdate(calendar: CalendarStatus(events: [lesson], accessDenied: false)), to: output + "-one.png")
render(DashboardUpdate(calendar: CalendarStatus(accessDenied: false)), to: output + "-empty.png")

let four = [lecture, lesson, lecture, lesson]
render(DashboardUpdate(calendar: CalendarStatus(events: four, moreCount: 3, moreColors: [navy], accessDenied: false)), to: output + "-four-more.png")
let nextDay = CalendarEvent(title: "Next day meeting", start: tomorrow(12, 40).addingTimeInterval(86400), end: tomorrow(14, 10).addingTimeInterval(86400), color: red)
render(DashboardUpdate(calendar: CalendarStatus(events: [lecture, lesson, nextDay], accessDenied: false)), to: output + "-multiple-days.png")

// Exercise every widget in either slot, duplicates, and the calendar's expanded state.
mode.previewWidgets(["calendar", "clock"])
render(DashboardUpdate(track: TrackInfo(title: "", artist: "", duration: 0, elapsed: 0,
                                      isPlaying: false, hasTrack: false),
                       calendar: CalendarStatus(events: four, accessDenied: false)),
       to: output + "-clock.png")
mode.previewWidgets(["clock", "usage"])
render(DashboardUpdate(), to: output + "-clock-left.png")
mode.previewWidgets(["calendar", "calendar"])
render(DashboardUpdate(calendar: CalendarStatus(events: four, accessDenied: false)),
       to: output + "-duplicate-calendar.png")
mode.stop()

// Exercise the same settle callback UIKit calls after a phone swipe, without synthesizing touch.
// Actual finger tracking, velocity and feel still need the iPhone.
let checkKey = "dashcheck." + UUID().uuidString
let checkPreference = "dashboard.widget." + checkKey
defer { UserDefaults.standard.removeObject(forKey: checkPreference) }
let slot = DashboardSlot(defaultID: "usage", key: checkKey)
slot.frame = CGRect(x: 0, y: 0, width: 321.5, height: 359)
slot.layoutIfNeeded()
let scroll = slot.subviews.first as! UIScrollView
func settlePage(_ page: Int, expected: String) {
    scroll.contentOffset.y = CGFloat(page) * slot.bounds.height
    slot.scrollViewDidEndDecelerating(scroll)
    precondition(slot.accessibilityLabel == expected)
    precondition(scroll.contentOffset.y == slot.bounds.height)
}
settlePage(0, expected: "Clock") // Backward wrap from Usage.
settlePage(2, expected: "Usage") // Forward wrap from Clock.
settlePage(2, expected: "Calendar and music")
settlePage(1, expected: "Calendar and music") // Cancelled/short drag.
let restored = DashboardSlot(defaultID: "usage", key: checkKey)
restored.frame = slot.frame
restored.layoutIfNeeded()
precondition(restored.accessibilityLabel == "Calendar and music")
slot.select("clock")
precondition(restored.accessibilityLabel == "Calendar and music") // Independent instances.
print("Widget settling passed: both directions, wrapping, cancelled drag, saved selection and independence")
