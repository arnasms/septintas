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

/// One usage limit as CodexBar reports it, titled by its length ("5 hours", "Week", "Month").
struct LimitWindow: Codable {
    var title: String
    var percent: Int
    var resets: Date?
    /// Length of the window. The phone shows a far-off reset as a date rather than a weekday.
    var minutes: Int?
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
    /// 0 = top card, 1 = bottom card. Older Macs leave it out: Claude goes on top, Codex below.
    var slot: Int? = nil
    /// Which account this is, shown after the provider name when both cards are the same provider.
    var accountName: String? = nil
    /// Cost comes from local logs that can't be split by account. With two cards of one provider,
    /// the top card shows no cost and the bottom one shows the total for both.
    var costShared: Bool? = nil
    /// True when this account's usage has never loaded (for example its login expired). The card still
    /// shows which account it is, with empty bars, instead of keeping whatever it showed before.
    var unavailable: Bool? = nil
    /// The account's limits, at most two, in CodexBar's order. Plans differ: Claude and paid Codex have a
    /// 5-hour and a weekly limit, free Codex has a single monthly one. Older Macs leave this out and the
    /// phone falls back to the session/week fields, which newer Macs still fill for older phones.
    var windows: [LimitWindow]? = nil
    /// When these numbers were fetched. Saved numbers are kept until their limits reset, so they can be old.
    var updatedAt: Date? = nil
    /// True when the Mac's latest try for this account failed and these are the last good numbers.
    var stale: Bool? = nil
    /// When the Mac will try again, sent while the numbers are stale or missing.
    var nextUpdateAt: Date? = nil
}

extension ProviderLimits {
    /// Reset times of this account's limits, from the windows when the Mac sent them.
    var resetDates: [Date] { (windows?.map(\.resets) ?? [sessionResets, weekResets]).compactMap { $0 } }

    /// Saved numbers stay useful until every limit they describe has reset.
    func allLimitsReset(at now: Date = Date()) -> Bool {
        let dates = resetDates
        return !dates.isEmpty && dates.allSatisfy { $0 <= now }
    }
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
