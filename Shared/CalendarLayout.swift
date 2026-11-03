import Foundation

/// Shared geometry keeps event capacity consistent during compact/full-height resizing.
enum CalendarLayout {
    static let maximumEvents = 8
    static let headerHeight = 16.0
    static let moreHeight = 16.0
    static let sectionGap = 3.0
    static let blockGap = 4.0
    static let eventHeight = 46.0

    static func visibleCount(_ status: CalendarStatus?, height: Double) -> Int {
        guard let status else { return 0 }
        let count = min(status.events.count, maximumEvents)
        for candidate in stride(from: count, through: 1, by: -1) {
            let days = (0..<candidate).filter { index in
                index == 0 || !Calendar.current.isDate(status.events[index - 1].start, inSameDayAs: status.events[index].start)
            }.count
            let more = status.remaining(after: candidate).count > 0
            let needed = Double(days) * (headerHeight + sectionGap) + Double(candidate) * eventHeight
                + Double(candidate - 1) * blockGap + (more ? sectionGap + moreHeight : 0)
            if needed <= height { return candidate }
        }
        return 0
    }
}
