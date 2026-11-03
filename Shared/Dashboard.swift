import Foundation

/// The dashboard's private messages inside `MessageType.modeData`: JSON, Mac -> phone.
/// Each message carries only what changed, and the phone keeps the rest. The phone formats all
/// dates itself. Its clock runs without the Mac, and the time tile needs nothing from here.
struct DashboardUpdate: Codable {
    /// nil leaves usage unchanged; a non-nil array replaces the entire snapshot (including []).
    var limits: [ProviderLimits]?
    var usageState: UsageState?
    var track: TrackInfo?
    /// New album art, sent only when the track's art changes.
    var art: Data?
    var calendar: CalendarStatus?
}

enum UsageState: String, Codable {
    case available, sourceMissing, unavailable
}

struct ProviderLimits: Codable {
    enum Provider: String, Codable { case claude, codex }
    var provider: Provider
    var sessionPercent: Int
    var sessionResets: Date?
    var weekPercent: Int
    var weekResets: Date?
    var costToday: Double
    var costMonth: Double
    /// True when the Mac has failed to refresh this for a while, and these are the last known numbers.
    var outOfDate: Bool
}

struct TrackInfo: Codable, Equatable {
    var title: String
    var artist: String
    var duration: Double
    /// Position when this message was sent. The phone moves the bar along from there.
    var elapsed: Double
    var isPlaying: Bool
    /// False when nothing is loaded in any player.
    var hasTrack: Bool
}

struct CalendarStatus: Codable {
    /// Upcoming events across days; the phone shows as many as fit, grouped by day.
    var events: [CalendarEvent] = []
    /// Events beyond the supplied list, and their calendars' colours without repeats.
    var moreCount = 0
    var moreColors: [CalendarColor] = []
    var accessDenied: Bool
    /// Totals let the phone count only the last visible day's hidden events.
    var days: [CalendarDaySummary]? = nil

    func remaining(after visibleCount: Int) -> (count: Int, colors: [CalendarColor]) {
        guard visibleCount > 0, visibleCount <= events.count else { return (0, []) }
        let day = events[visibleCount - 1].start
        let visibleOnDay = events.prefix(visibleCount).filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.count
        let hiddenOnDay = events.dropFirst(visibleCount).filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        if let summary = days?.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            let hiddenColors = summary.eventColors.map { Array($0.dropFirst(visibleOnDay)).compactMap { $0 } }
                ?? hiddenOnDay.compactMap { $0.color }
            let colors = hiddenColors.reduce(into: [CalendarColor]()) { result, color in
                if !result.contains(color) { result.append(color) }
            }
            return (max(0, summary.count - visibleOnDay), colors)
        }
        // Older senders' moreCount could include the entire fortnight; don't label it as one day.
        return (hiddenOnDay.count, hiddenOnDay.compactMap { $0.color })
    }
}

struct CalendarDaySummary: Codable {
    var date: Date
    var count: Int
    var colors: [CalendarColor]
    /// In chronological order, including nil for an event without a calendar colour.
    var eventColors: [CalendarColor?]? = nil
}

struct CalendarEvent: Codable {
    var title: String
    var start: Date
    var end: Date
    /// The colour of the calendar the event belongs to.
    var color: CalendarColor?
}

struct CalendarColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
}
