import Foundation
let today = Calendar.current.startOfDay(for: Date())
func event(_ day: Date, index: Int) -> CalendarEvent {
    let start = day.addingTimeInterval(Double(index * 3600))
    return CalendarEvent(title: "Event \(index)", start: start, end: start.addingTimeInterval(1800))
}
let six = CalendarStatus(events: (0..<6).map { event(today, index: $0) }, accessDenied: false)
precondition(CalendarLayout.visibleCount(six, height: 218) == 3)
precondition(CalendarLayout.visibleCount(six, height: 331) == 6)
precondition(six.remaining(after: CalendarLayout.visibleCount(six, height: 218)).count == 3)
precondition(six.remaining(after: CalendarLayout.visibleCount(six, height: 331)).count == 0)
let eight = CalendarStatus(events: (0..<8).map { event(today, index: $0) }, accessDenied: false)
precondition(CalendarLayout.visibleCount(eight, height: 331) == 5) // Reserve the remaining-events row.
precondition(CalendarLayout.visibleCount(six, height: 0) == 0)
precondition(CalendarLayout.visibleCount(CalendarStatus(accessDenied: false), height: 331) == 0)
let daily = CalendarStatus(events: (0..<6).map { event(today.addingTimeInterval(Double($0) * 86400), index: 0) }, accessDenied: false)
precondition(CalendarLayout.visibleCount(daily, height: 331) == 4)
print("Calendar capacity passed: compact 3 → expanded 6 → compact 3, day headers and remaining counts")
