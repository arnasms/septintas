import UIKit
import ObjectiveC

// Draws the real phone dashboard to PNGs on the Mac, using sample numbers,
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

// Usage updates replace snapshots; unrelated messages must preserve the current state.
let usage = UsageWidget()
let sample = ProviderLimits(provider: .claude, sessionPercent: 47, weekPercent: 10,
                            costToday: 1, costMonth: 2, outOfDate: false)
usage.apply(DashboardUpdate(limits: [sample], usageState: .available))
precondition(usage.accessibilityValue == "Usage available")
let missing = DashboardUpdate(limits: [], usageState: .sourceMissing)
let decodedMissing = try! JSONDecoder().decode(DashboardUpdate.self, from: JSONEncoder().encode(missing))
precondition(decodedMissing.limits?.isEmpty == true)
usage.apply(decodedMissing)
precondition(usage.accessibilityValue?.contains("Install it on your Mac") == true)
usage.apply(DashboardUpdate(track: TrackInfo(title: "", artist: "", duration: 0, elapsed: 0,
                                          isPlaying: false, hasTrack: false)))
precondition(usage.accessibilityValue?.contains("Install it on your Mac") == true)
usage.apply(DashboardUpdate(limits: [])) // Older sender, no availability reason.
precondition(usage.accessibilityValue?.contains("Usage unavailable") == true)
usage.apply(DashboardUpdate(limits: [sample], usageState: .available))
precondition(usage.accessibilityValue == "Usage available")
mode.previewWidgets(["usage", "calendar"])
render(missing, to: output + "-usage-missing.png")
let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    .appendingPathComponent("dashboard.json")
let cached = try! JSONDecoder().decode(DashboardUpdate.self, from: Data(contentsOf: cacheURL))
precondition(cached.limits?.isEmpty == true && cached.usageState == .sourceMissing)
let restarted = DashboardPhoneMode()
restarted.start { _ in }
restarted.stop()
render(DashboardUpdate(limits: [], usageState: .unavailable), to: output + "-usage-unavailable.png")
print("Usage states passed: populated, missing, unavailable, unrelated update, recovery and wire encoding")
// Render and validate the real views with representative device safe areas.
func layoutTree(_ root: UIView) {
    root.setNeedsLayout()
    root.layoutIfNeeded()
    root.subviews.forEach(layoutTree)
}
func snapshot(_ root: UIView, _ path: String) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(bounds: root.bounds, format: format).image {
        root.layer.render(in: $0.cgContext)
    }
    try! image.pngData()!.write(to: URL(fileURLWithPath: path))
}

// Inject insets on the view itself using a test-only runtime subclass. This avoids relying on
// Mac window chrome, and exercises both sides of an asymmetric notch after a live resize.
var insetsKey: UInt8 = 0
let safeInsetsBlock: @convention(block) (UIView) -> UIEdgeInsets = { view in
    (objc_getAssociatedObject(view, &insetsKey) as? NSValue)?.uiEdgeInsetsValue ?? .zero
}
func setDevice(_ root: UIView, size: CGSize, insets: UIEdgeInsets) {
    let currentName = NSStringFromClass(type(of: root))
    let name = currentName.hasPrefix("LayoutCheck_") ? currentName : "LayoutCheck_" + currentName
    let subclass: AnyClass = NSClassFromString(name) ?? objc_allocateClassPair(type(of: root), name, 0)!
    if NSClassFromString(name) == nil {
        class_addMethod(subclass, #selector(getter: UIView.safeAreaInsets),
                        imp_implementationWithBlock(safeInsetsBlock), "{UIEdgeInsets=dddd}@:")
        objc_registerClassPair(subclass)
    }
    object_setClass(root, subclass)
    objc_setAssociatedObject(root, &insetsKey, NSValue(uiEdgeInsets: insets), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    root.frame = CGRect(origin: .zero, size: size)
    root.safeAreaInsetsDidChange()
    layoutTree(root)
}
let cases: [(String, CGSize, UIEdgeInsets)] = [
    ("se", CGSize(width: 568, height: 320), .zero),
    ("iphone7", CGSize(width: 667, height: 375), .zero),
    ("plus", CGSize(width: 736, height: 414), .zero),
    ("mini", CGSize(width: 812, height: 375), UIEdgeInsets(top: 0, left: 50, bottom: 21, right: 50)),
    ("notch-left", CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 0)),
    ("notch-right", CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 47)),
    ("max", CGSize(width: 932, height: 430), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
]
let waiting = WaitingView()
waiting.setAppActive(false)
for (name, size, insets) in cases {
    setDevice(view, size: size, insets: insets)
    let safe = view.bounds.inset(by: insets)
    let slots = view.subviews[0].subviews.compactMap { $0 as? DashboardSlot }
    precondition(slots.count == 2)
    for ids in [["usage", "calendar"], ["clock", "usage"], ["calendar", "calendar"]] {
        mode.previewWidgets(ids)
        layoutTree(view)
        for slot in slots {
            precondition(safe.insetBy(dx: 6, dy: 6).contains(slot.frame), "Unsafe slot: \(name)")
            precondition(slot.bounds.height >= 288 && slot.bounds.width >= 264)
        }
        snapshot(view, output + "-" + name + "-" + ids.joined(separator: "-") + ".png")
    }
    mode.previewWidgets(["usage", "calendar"])
    render(DashboardUpdate(track: TrackInfo(title: "Long song title for compact layouts", artist: "Some Artist",
                                           duration: 200, elapsed: 80, isPlaying: true, hasTrack: true)),
           to: output + "-" + name + "-music.png")
    layoutTree(view)
    if name == "iphone7" {
        precondition(slots[0].frame == CGRect(x: 8, y: 8, width: 321.5, height: 359))
        precondition(slots[1].frame == CGRect(x: 337.5, y: 8, width: 321.5, height: 359))
    }
    for welcome in [false, true] {
        waiting.setWelcome(welcome)
        setDevice(waiting, size: size, insets: insets)
        for label in waiting.subviews.compactMap({ $0 as? UILabel }) where !label.isHidden {
            precondition(safe.contains(label.frame), "Unsafe waiting text: \(name)")
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            precondition(needed.height <= label.bounds.height + 1, "Clipped waiting text: \(name)")
        }
        snapshot(waiting, output + "-" + name + (welcome ? "-welcome.png" : "-waiting.png"))
    }
}
print("Layout checks passed: 7 landscape sizes/safe areas, widget variants, live resize and waiting/welcome")
