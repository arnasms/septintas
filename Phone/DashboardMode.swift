import CoreText
import UIKit

/// Limits on the left half; Now Playing above a two-thirds-height calendar on the right.
final class DashboardPhoneMode: PhoneMode {
    let id = ModeID.dashboard
    var onReady: (() -> Void)?

    private let dashboard = DashboardView()
    var view: UIView { dashboard }
    func setWidgetBackgroundAlpha(_ alpha: CGFloat) { dashboard.setWidgetBackgroundAlpha(alpha) }
    func setContentColorProgress(_ progress: CGFloat) { dashboard.setContentColorProgress(progress) }

    private let decoder = JSONDecoder()
    private var timer: Timer?
    private var hasLimits = false
    private var hasTrack = false

    func start(send: @escaping (Data) -> Void) {
        dashboard.resetPixelShift()
        restoreSaved()
        dashboard.tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.dashboard.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dashboard.resetPixelShift()
    }

    func receive(_ data: Data) {
        guard let update = try? decoder.decode(DashboardUpdate.self, from: data) else { return }
        DispatchQueue.main.async { [self] in
            dashboard.apply(update)
            if update.limits != nil { hasLimits = true }
            if update.track != nil { hasTrack = true }
            if update.limits != nil || update.calendar != nil { save(update) }
            announceIfReady()
        }
    }

    /// Only move on once the tiles are filled, so the dashboard never slides in half empty.
    private func announceIfReady() {
        guard hasLimits, hasTrack else { return }
        onReady?()
        onReady = nil
    }

    // MARK: Last known numbers

    /// The Mac needs several seconds to fetch limits, so the phone remembers the last ones to show
    /// straight away. They get replaced as soon as the fresh ones arrive.
    private struct Saved: Codable {
        var savedAt: Date
        var limits: [ProviderLimits]?
        var calendar: CalendarStatus?
    }

    private var saved = Saved(savedAt: Date())
    private let outOfDateAfter: TimeInterval = 300

    private var savedURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("dashboard.json")
    }

    private func save(_ update: DashboardUpdate) {
        saved.savedAt = Date()
        saved.limits = update.limits ?? saved.limits
        saved.calendar = update.calendar ?? saved.calendar
        guard let url = savedURL, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func restoreSaved() {
        guard let url = savedURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        saved = value
        var limits = value.limits
        if Date().timeIntervalSince(value.savedAt) > outOfDateAfter {
            limits = limits?.map { var old = $0; old.outOfDate = true; return old }
        }
        var calendar = value.calendar
        calendar?.events.removeAll { $0.end < Date() }
        dashboard.apply(DashboardUpdate(limits: limits, calendar: calendar))
        hasLimits = limits != nil
    }
}

private let tileColor = UIColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)
private let secondaryText = UIColor(red: 0.631, green: 0.631, blue: 0.651, alpha: 1)
private let trackColor = UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
private let ruleColor = UIColor(red: 0.22, green: 0.22, blue: 0.227, alpha: 1)
private let claudeColor = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
private let codexColor = UIColor(red: 0.898, green: 0.898, blue: 0.918, alpha: 1)
private let appLocale = Locale(identifier: "en_US")

/// Split atmosphere at 20% over #0C0C0C, matching the selected preview.
private final class TileSurface: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
}

private final class UsageTile: UIView {
    let surface = TileSurface()

    init() {
        super.init(frame: .zero)
        addSubview(surface)
        let gradient = surface.layer as! CAGradientLayer
        let stops: [(CGFloat, CGFloat, CGFloat)] = [(52, 36, 30), (21, 18, 17), (18, 21, 26), (35, 42, 52)]
        gradient.colors = stops.map { r, g, b in
            UIColor(red: (12 + (r - 12) * 0.20) / 255,
                    green: (12 + (g - 12) * 0.20) / 255,
                    blue: (12 + (b - 12) * 0.20) / 255, alpha: 1).cgColor
        }
        gradient.locations = [0, 0.46, 0.54, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
    }
}

private func formatted(_ date: Date, _ format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = appLocale
    formatter.dateFormat = format
    return formatter.string(from: date)
}

/// Stylistic alternative 3 is San Francisco's centred colon, used by Apple's clock and calendar.
private func withCentredColon(_ font: UIFont) -> UIFont {
    let descriptor = font.fontDescriptor.addingAttributes([
        .featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kStylisticAlternativesType,
            UIFontDescriptor.FeatureKey.selector: kStylisticAltThreeOnSelector,
        ]],
    ])
    return UIFont(descriptor: descriptor, size: font.pointSize)
}

private func label(size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white) -> UILabel {
    let view = UILabel()
    view.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
    view.textColor = color
    return view
}

private final class DashboardView: UIView {
    private let content = UIView()
    private var nextPixelShift = ProcessInfo.processInfo.systemUptime + 60
    private var pixelShiftStep = 0
    private let foreground = DashboardForeground()
    private var showsMusic = false
    private var receivedTrack = false
    private var latestTrack: TrackInfo?
    private var presenceGeneration = 0

    func setContentColorProgress(_ progress: CGFloat) { foreground.setProgress(progress, in: self) }
    private let limitsTile = UsageTile()
    private let rule = UIView()
    private let claude = ProviderSection(provider: .claude, color: claudeColor, logoColor: claudeColor)
    private let codex = ProviderSection(provider: .codex, color: codexColor, logoColor: .white)
    private let playing = NowPlayingTile()
    private let calendarTile = CalendarTile()

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(content)
        rule.backgroundColor = ruleColor
        content.addSubview(limitsTile)
        limitsTile.addSubview(claude)
        limitsTile.addSubview(rule)
        limitsTile.addSubview(codex)
        content.addSubview(playing)
        content.addSubview(calendarTile)
        playing.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds/center preserve the shift when layout changes or the music card animates.
        content.bounds = bounds
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let pad: CGFloat = 8
        let gap: CGFloat = 8
        let columnWidth = (bounds.width - pad * 2 - gap) / 2
        let inner = bounds.height - pad * 2

        limitsTile.frame = CGRect(x: pad, y: pad, width: columnWidth, height: inner)
        let sectionInsetX: CGFloat = 16
        let sectionInsetY: CGFloat = 6
        let sectionHeight = (inner - sectionInsetY * 2 - 1) / 2
        let sectionWidth = columnWidth - sectionInsetX * 2
        claude.frame = CGRect(x: sectionInsetX, y: sectionInsetY, width: sectionWidth, height: sectionHeight)
        rule.frame = CGRect(x: sectionInsetX, y: sectionInsetY + sectionHeight, width: sectionWidth, height: 1)
        codex.frame = CGRect(x: sectionInsetX, y: sectionInsetY + sectionHeight + 1, width: sectionWidth, height: sectionHeight)

        let rightX = pad + columnWidth + gap
        let playingHeight: CGFloat = 105
        playing.bounds = CGRect(x: 0, y: 0, width: columnWidth, height: playingHeight)
        playing.center = CGPoint(x: rightX + columnWidth / 2, y: pad + playingHeight / 2)
        let musicSpace = showsMusic ? playingHeight + gap : 0
        calendarTile.frame = CGRect(x: rightX, y: pad + musicSpace, width: columnWidth, height: inner - musicSpace)
    }

    private func updateMusicPresence(_ visible: Bool, animated: Bool) {
        guard visible != showsMusic else { return }
        presenceGeneration += 1
        let generation = presenceGeneration
        calendarTile.finishResize()
        layoutIfNeeded()
        showsMusic = visible
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            playing.isHidden = !visible
            if !visible, let latestTrack { playing.apply(latestTrack) }
            playing.alpha = visible ? 1 : 0
            playing.transform = .identity
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let targetHeight = bounds.height - 16 - (visible ? 113 : 0)
        let oldCount = calendarTile.prepareResize(to: targetHeight)
        if visible, playing.isHidden {
            playing.alpha = 0
            playing.transform = CGAffineTransform(translationX: 0, y: -28)
        }
        playing.isHidden = false
        setNeedsLayout()
        UIView.animate(withDuration: 0.65, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
            self.layoutIfNeeded()
            self.playing.alpha = visible ? 1 : 0
            self.playing.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: -28)
        }) { [weak self] _ in
            guard let self, generation == self.presenceGeneration else { return }
            self.playing.isHidden = !visible
            if !visible, let latestTrack = self.latestTrack { self.playing.apply(latestTrack) }
            self.calendarTile.finishResize()
        }
        if !visible { calendarTile.staggerNewEvents(after: oldCount) }
    }

    func setWidgetBackgroundAlpha(_ alpha: CGFloat) {
        limitsTile.surface.alpha = alpha
        playing.surface.alpha = alpha
        calendarTile.setBackgroundAlpha(alpha)
    }

    func tick() {
        updatePixelShift()
        let phase = foreground.progress
        foreground.setProgress(1, in: self)
        calendarTile.tick()
        playing.tick()
        claude.tick()
        codex.tick()
        foreground.setProgress(phase, in: self)
    }

    func resetPixelShift() {
        pixelShiftStep = 0
        nextPixelShift = ProcessInfo.processInfo.systemUptime + 60
        content.transform = .identity
    }

    /// Walk a small square once per minute. The existing 8pt padding keeps every tile on screen.
    private func updatePixelShift() {
        let now = ProcessInfo.processInfo.systemUptime
        guard window != nil, UIApplication.shared.applicationState == .active,
              now >= nextPixelShift else { return }
        nextPixelShift = now + 60
        let offsets: [CGPoint] = [
            CGPoint(x: 2, y: 0),
            CGPoint(x: 2, y: 1), CGPoint(x: 2, y: 2),
            CGPoint(x: 1, y: 2), CGPoint(x: 0, y: 2),
            CGPoint(x: -1, y: 2), CGPoint(x: -2, y: 2),
            CGPoint(x: -2, y: 1), CGPoint(x: -2, y: 0),
            CGPoint(x: -2, y: -1), CGPoint(x: -2, y: -2),
            CGPoint(x: -1, y: -2), CGPoint(x: 0, y: -2),
            CGPoint(x: 1, y: -2), CGPoint(x: 2, y: -2),
            CGPoint(x: 2, y: -1),
        ]
        let offset = offsets[pixelShiftStep]
        pixelShiftStep = (pixelShiftStep + 1) % offsets.count
        let scale = window?.screen.scale ?? UIScreen.main.scale
        UIView.performWithoutAnimation {
            content.transform = CGAffineTransform(translationX: (offset.x * scale).rounded() / scale,
                                                  y: (offset.y * scale).rounded() / scale)
        }
    }

    func apply(_ update: DashboardUpdate) {
        let phase = foreground.progress
        foreground.setProgress(1, in: self)
        for limits in update.limits ?? [] {
            (limits.provider == .claude ? claude : codex).apply(limits)
        }
        if let art = update.art { playing.setArt(art) }
        if let track = update.track {
            latestTrack = track
            // Keep the last song visible while its card exits, rather than flashing an idle label.
            if track.hasTrack || !showsMusic { playing.apply(track) }
            updateMusicPresence(track.hasTrack && track.isPlaying, animated: receivedTrack && window != nil && phase >= 1)
            receivedTrack = true
        }
        if let status = update.calendar { calendarTile.apply(status) }
        foreground.setProgress(phase, in: self)
    }
}

// MARK: Limits

private final class ProviderSection: UIView {
    private let logo = CAShapeLayer()
    private let name = UILabel()
    private let warning = label(size: 13, color: secondaryText)
    private let session: LimitRow
    private let week: LimitRow
    private let today = label(size: 15, color: secondaryText)
    private let month = label(size: 15, color: secondaryText)
    private var limits: ProviderLimits?

    init(provider: ProviderLimits.Provider, color: UIColor, logoColor: UIColor) {
        session = LimitRow(title: "5 hours", color: color)
        week = LimitRow(title: "Week", color: color)
        super.init(frame: .zero)
        logo.path = ProviderLogos.path(for: provider, size: 26)
        logo.fillColor = logoColor.cgColor
        layer.addSublayer(logo)
        name.text = provider == .claude ? "Claude" : "Codex"
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        name.textColor = .white
        warning.textAlignment = .right
        warning.text = ""
        for view in [name, warning, session, week, today, month] { addSubview(view) }
        month.textAlignment = .right
        today.attributedText = Self.cost(nil, "today")
        month.attributedText = Self.cost(nil, "this month")
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ value: ProviderLimits) {
        limits = value
        today.attributedText = Self.cost(value.costToday, "today")
        month.attributedText = Self.cost(value.costMonth, "this month")
        warning.text = value.outOfDate ? "Out of date" : ""
        tick()
    }

    /// Runs every second, so a reset changing from a weekday to a time happens by itself at midnight.
    func tick() {
        guard let limits else { return }
        session.set(percent: limits.sessionPercent, when: limits.sessionResets.map { formatted($0, "h:mm a") })
        week.set(percent: limits.weekPercent, when: limits.weekResets.map(Self.weekReset))
    }

    private static func weekReset(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? formatted(date, "h:mm a") : formatted(date, "EEEE")
    }

    private static func cost(_ value: Double?, _ words: String) -> NSAttributedString {
        let number = value.map { String(format: "$%.2f", $0) } ?? "–"
        let text = NSMutableAttributedString(string: number, attributes: [.foregroundColor: UIColor.white])
        text.append(NSAttributedString(string: " " + words, attributes: [.foregroundColor: secondaryText]))
        return text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let headerHeight: CGFloat = 28
        let rowHeight = LimitRow.height
        let costHeight: CGFloat = 19
        // Four items, so five equal gaps: the spare height is shared out with no dead band anywhere.
        let spare = max(0, bounds.height - headerHeight - rowHeight * 2 - costHeight)
        let space = spare / 5
        var y = space
        logo.frame = CGRect(x: 0, y: y + 1, width: 26, height: 26)
        name.frame = CGRect(x: 33, y: y, width: 120, height: headerHeight)
        warning.frame = CGRect(x: 153, y: y, width: width - 153, height: headerHeight)
        y += headerHeight + space
        session.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        y += rowHeight + space
        week.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        y += rowHeight + space
        today.frame = CGRect(x: 0, y: y, width: width / 2, height: costHeight)
        month.frame = CGRect(x: width / 2, y: y, width: width / 2, height: costHeight)
    }
}

private final class LimitRow: UIView {
    static let height: CGFloat = 34

    private let title = label(size: 15, color: secondaryText)
    private let value = label(size: 15, color: secondaryText)
    private let track = UIView()
    private let fill = UIView()
    private var percent = 0

    init(title text: String, color: UIColor) {
        super.init(frame: .zero)
        title.text = text
        value.textAlignment = .right
        track.backgroundColor = trackColor
        fill.backgroundColor = color
        for bar in [track, fill] {
            bar.layer.cornerRadius = 5
            bar.layer.cornerCurve = .continuous
        }
        for view in [title, value, track] { addSubview(view) }
        track.addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(percent newPercent: Int, when: String?) {
        percent = max(0, min(100, newPercent))
        let text = NSMutableAttributedString(string: "\(percent)%", attributes: [.foregroundColor: UIColor.white])
        if let when {
            text.append(NSAttributedString(string: " · " + when, attributes: [.foregroundColor: secondaryText]))
        }
        value.attributedText = text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 0, y: 0, width: 80, height: 19)
        value.frame = CGRect(x: 80, y: 0, width: bounds.width - 80, height: 19)
        track.frame = CGRect(x: 0, y: 24, width: bounds.width, height: 10)
        fill.frame = CGRect(x: 0, y: 0, width: max(percent > 0 ? 10 : 0, bounds.width * CGFloat(percent) / 100), height: 10)
    }
}

// MARK: Now Playing

private final class NowPlayingTile: UIView {
    let surface = TileSurface()
    private var background: CAGradientLayer { surface.layer as! CAGradientLayer }
    private var artworkGeneration = 0
    private let art = UIImageView()
    private let title = label(size: 19, weight: .semibold)
    private static let secondaryColor = UIColor(red: ArtworkPalette.secondaryText.red / 255,
                                                green: ArtworkPalette.secondaryText.green / 255,
                                                blue: ArtworkPalette.secondaryText.blue / 255, alpha: 1)
    private let artist = label(size: 16, color: NowPlayingTile.secondaryColor)
    private let track = UIView()
    private let fill = UIView()

    private var info: TrackInfo?
    private var receivedAt = Date()

    init() {
        super.init(frame: .zero)
        surface.backgroundColor = tileColor
        addSubview(surface)
        clipsToBounds = true
        background.startPoint = CGPoint(x: 0, y: 0)
        background.endPoint = CGPoint(x: 1, y: 1)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        art.backgroundColor = trackColor
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.cornerRadius = 10
        art.layer.cornerCurve = .continuous
        track.backgroundColor = trackColor
        fill.backgroundColor = .white
        track.layer.cornerRadius = 2.5
        fill.layer.cornerRadius = 2.5
        title.text = "Not Playing"
        title.textColor = Self.secondaryColor
        for view in [art, title, artist, track] { addSubview(view) }
        track.addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setArt(_ data: Data) {
        artworkGeneration += 1
        let generation = artworkGeneration
        let image = UIImage(data: data)
        art.image = image
        guard let cgImage = image?.cgImage else { background.colors = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let palette = ArtworkPalette.colors(from: Self.samples(cgImage))
            let colors = ArtworkPalette.backgroundStops(from: palette).map { c -> CGColor in
                return UIColor(red: c.red / 255, green: c.green / 255, blue: c.blue / 255, alpha: 1).cgColor
            }
            DispatchQueue.main.async {
                guard let self, generation == self.artworkGeneration else { return }
                self.background.colors = colors.isEmpty ? nil : colors
            }
        }
    }

    /// An 80px sample bounds CPU cost; 16-step RGB bins match the palette prototype.
    private static func samples(_ image: CGImage) -> [ArtworkPalette.Sample] {
        let scale = min(1, 80.0 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        var bins: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]
        var order: [Int] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r / 16) * 256 + (g / 16) * 16 + b / 16
            if bins[key] == nil { bins[key] = (0, 0, 0, 0); order.append(key) }
            let old = bins[key]!
            bins[key] = (old.r + r, old.g + g, old.b + b, old.count + 1)
        }
        return order.compactMap { key in
            guard let bin = bins[key] else { return nil }
            return ArtworkPalette.Sample(color: .init(red: (Double(bin.r) / Double(bin.count)).rounded(),
                green: (Double(bin.g) / Double(bin.count)).rounded(), blue: (Double(bin.b) / Double(bin.count)).rounded()), count: bin.count)
        }
    }

    func apply(_ value: TrackInfo) {
        info = value
        receivedAt = Date()
        if !value.hasTrack {
            title.text = "Not Playing"
            title.textColor = Self.secondaryColor
            artist.text = ""
            art.image = nil
            artworkGeneration += 1
            background.colors = nil
        } else {
            title.text = value.title
            title.textColor = .white
            artist.text = value.artist
        }
        tick()
        setNeedsLayout()
    }

    func tick() {
        guard let info, info.hasTrack, info.duration > 0 else {
            fill.frame.size.width = 0
            track.isHidden = true
            return
        }
        track.isHidden = false
        let moved = info.isPlaying ? Date().timeIntervalSince(receivedAt) : 0
        let progress = min(1, max(0, (info.elapsed + moved) / info.duration))
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * progress, height: 5)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
        let inset: CGFloat = 12
        let side = bounds.height - inset * 2
        art.frame = CGRect(x: inset, y: inset, width: side, height: side)
        let x = inset + side + 14
        let width = bounds.width - x - 14
        let hasTrack = info?.hasTrack == true
        artist.isHidden = !hasTrack
        if !hasTrack {
            title.frame = CGRect(x: x, y: (bounds.height - 24) / 2, width: width, height: 24)
            track.isHidden = true
            return
        }
        // Title, artist and bar sit together as one block, centred on the art.
        let blockHeight: CGFloat = 24 + 21 + 12 + 5
        var y = (bounds.height - blockHeight) / 2
        title.frame = CGRect(x: x, y: y, width: width, height: 24)
        y += 24
        artist.frame = CGRect(x: x, y: y, width: width, height: 21)
        y += 21 + 12
        track.frame = CGRect(x: x, y: y, width: width, height: 5)
        tick()
    }
}

// MARK: Calendar

/// Upcoming events use the tile directly, without a date row or its reserved spacing.
private final class CalendarTile: UIView {
    private let calendar = CalendarSection()
    private let surface = TileSurface()
    private var background: CAGradientLayer { surface.layer as! CAGradientLayer }

    init() {
        super.init(frame: .zero)
        // Sampled from the supplied iPhone Calendar screenshot: top pixel and darkest bottom-50 pixel.
        background.colors = [UIColor(white: 32.0 / 255, alpha: 1).cgColor,
                             UIColor(white: 12.0 / 255, alpha: 1).cgColor]
        background.startPoint = CGPoint(x: 0.5, y: 0)
        background.endPoint = CGPoint(x: 0.5, y: 1)
        addSubview(surface)
        clipsToBounds = true
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        addSubview(calendar)
        calendar.clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }
    func apply(_ status: CalendarStatus) { calendar.apply(status) }
    func tick() { calendar.tick() }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        surface.alpha = alpha
        calendar.setBackgroundAlpha(alpha)
    }

    func prepareResize(to height: CGFloat) -> Int { calendar.prepareResize(to: max(0, height - 28)) }
    func staggerNewEvents(after count: Int) { calendar.staggerNewEvents(after: count) }
    func finishResize() { calendar.finishResize() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
        calendar.frame = bounds.insetBy(dx: 14, dy: 14)
    }
}

/// The day in small caps, as many events as fit, then a count of the remaining events.
private final class CalendarSection: UIView {
    private static let maxMoreBars = 3
    private static let headerHeight = CGFloat(CalendarLayout.headerHeight)
    private static let moreHeight = CGFloat(CalendarLayout.moreHeight)
    private static let sectionGap = CGFloat(CalendarLayout.sectionGap)
    private static let blockGap = CGFloat(CalendarLayout.blockGap)

    private let headers = (0..<CalendarLayout.maximumEvents).map { _ in label(size: 13, weight: .semibold, color: secondaryText) }
    private let blocks = (0..<CalendarLayout.maximumEvents).map { _ in EventBlock() }
    private let moreBars = (0..<CalendarSection.maxMoreBars).map { _ in UIView() }
    private let more = label(size: 13, color: secondaryText)
    private let message = UILabel()
    private var status: CalendarStatus?
    private var resizeCount: Int?
    private var resizeGeneration = 0

    init() {
        super.init(frame: .zero)
        message.font = .systemFont(ofSize: 16)
        message.textColor = secondaryText
        message.textAlignment = .center
        message.numberOfLines = 2
        for view in headers + [more, message] { addSubview(view) }
        for view in blocks + moreBars { addSubview(view) }
        for view in moreBars { view.layer.cornerRadius = EventBlock.barWidth / 2 }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        for block in blocks { block.setBackgroundAlpha(alpha) }
    }

    private var shownEvents: Int {
        if let resizeCount { return min(resizeCount, status?.events.count ?? 0, blocks.count) }
        return CalendarLayout.visibleCount(status, height: Double(bounds.height))
    }

    func prepareResize(to height: CGFloat) -> Int {
        let oldCount = shownEvents
        let newCount = CalendarLayout.visibleCount(status, height: Double(height))
        resizeGeneration += 1
        resizeCount = max(oldCount, newCount)
        setNeedsLayout()
        layoutIfNeeded()
        for index in oldCount..<max(oldCount, newCount) {
            for view in [blocks[index], headers[index]] {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: 8)
            }
        }
        return oldCount
    }

    func staggerNewEvents(after count: Int) {
        guard count < shownEvents else { return }
        let generation = resizeGeneration
        for index in count..<shownEvents {
            UIView.animate(withDuration: 0.25, delay: 0.14 + Double(index - count) * 0.08,
                           options: [.curveEaseOut, .beginFromCurrentState], animations: { [weak self] in
                guard let self, generation == self.resizeGeneration else { return }
                for view in [self.blocks[index], self.headers[index]] {
                    view.alpha = 1
                    view.transform = .identity
                }
            })
        }
    }

    func finishResize() {
        resizeGeneration += 1
        resizeCount = nil
        for view in blocks + headers {
            view.layer.removeAllAnimations()
            view.alpha = 1
            view.transform = .identity
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func startsDay(at index: Int) -> Bool {
        guard let events = status?.events, index < events.count else { return false }
        return index == 0 || !Calendar.current.isDate(events[index - 1].start, inSameDayAs: events[index].start)
    }

    private var remainingCount: Int { status?.remaining(after: shownEvents).count ?? 0 }
    private var showsMore: Bool { shownEvents > 0 && remainingCount > 0 }

    func apply(_ value: CalendarStatus) {
        status = value
        refreshContents()
        tick()
        setNeedsLayout()
    }

    private func refreshContents() {
        guard let value = status else { return }
        message.isHidden = shownEvents > 0
        message.text = value.accessDenied ? "Calendar is off\nAllow it in the Mac's settings" : "Nothing coming up"

        for (index, block) in blocks.enumerated() {
            headers[index].isHidden = index >= shownEvents || !startsDay(at: index)
            block.isHidden = index >= shownEvents
            if index < shownEvents { block.show(value.events[index]) }
        }

        more.isHidden = resizeCount != nil || !showsMore
        more.text = remainingCount == 1 ? "1 more event" : "\(remainingCount) more events"
        for (index, view) in moreBars.enumerated() {
            let colors = value.remaining(after: shownEvents).colors
            view.isHidden = resizeCount != nil || !showsMore || index >= max(colors.count, 1)
            view.backgroundColor = index < colors.count ? EventBlock.displayColor(colors[index]) : secondaryText
        }
    }

    /// Runs every second, so "Tomorrow" becomes "Today" by itself at midnight.
    func tick() {
        guard let events = status?.events else { return }
        for index in 0..<min(events.count, headers.count) {
            headers[index].text = Self.dayText(events[index].start)
        }
    }

    private static func dayText(_ start: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(start) || start < Date() { return "TODAY" }
        if calendar.isDateInTomorrow(start) { return "TOMORROW" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: start)).day ?? 0
        return (days < 7 ? formatted(start, "EEEE") : formatted(start, "MMMM d")).uppercased()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshContents()
        let width = bounds.width
        message.frame = bounds
        var y: CGFloat = 0
        for (index, block) in blocks.enumerated() where !block.isHidden {
            if !headers[index].isHidden {
                headers[index].frame = CGRect(x: 0, y: y, width: width, height: Self.headerHeight)
                y += Self.headerHeight + Self.sectionGap
            }
            block.frame = CGRect(x: 0, y: y, width: width, height: EventBlock.height)
            y += EventBlock.height + Self.blockGap
        }
        y += Self.sectionGap - Self.blockGap

        // These bars line up under the ones in the event blocks.
        var x = EventBlock.barInset
        for view in moreBars where !view.isHidden {
            view.frame = CGRect(x: x, y: y + 1, width: EventBlock.barWidth, height: Self.moreHeight - 2)
            x += EventBlock.barWidth + 3
        }
        more.frame = CGRect(x: x + 3, y: y, width: width - x - 3, height: Self.moreHeight)
    }
}

/// One event, tinted with its calendar's colour and with a bar down the left.
private final class EventBlock: UIView {
    static let height = CGFloat(CalendarLayout.eventHeight)
    static let barWidth: CGFloat = 4
    /// The bar sits this far inside the block, so the block's corner is the bar's plus this gap.
    static let barInset: CGFloat = 3

    private static let timeFont = withCentredColon(.systemFont(ofSize: 14))
    private static let fallbackColor = UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)

    private var tint: UIColor = .clear
    private var backgroundAlpha: CGFloat = 1
    private let bar = UIView()
    private let title = UILabel()
    private let time = UILabel()

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = Self.barWidth / 2 + Self.barInset
        layer.cornerCurve = .continuous
        bar.layer.cornerRadius = Self.barWidth / 2
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        for view in [bar, title, time] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ event: CalendarEvent) {
        let color = event.color.map(Self.displayColor) ?? Self.fallbackColor
        tint = color
        backgroundColor = color.withAlphaComponent(0.17 * backgroundAlpha)
        bar.backgroundColor = color
        title.textColor = color
        title.text = event.title
        time.attributedText = Self.timeText(start: event.start, end: event.end, color: color)
    }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        backgroundAlpha = alpha
        backgroundColor = tint.withAlphaComponent(0.17 * alpha)
    }

    /// Dark calendar colours can't be read on a dark tile, so like Apple's widget this lifts them
    /// while keeping their hue. Bright ones pass through untouched.
    static func displayColor(_ color: CalendarColor) -> UIColor {
        let original = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        guard original.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil),
              brightness < 0.6 else { return original }
        return UIColor(hue: hue, saturation: min(saturation, 0.5), brightness: 0.72, alpha: 1)
    }

    /// Apple's way of writing a time range: "12:40–2:10PM" and "1–2PM", with a small AM/PM that
    /// appears on the start time only when it differs from the end's.
    private static func timeText(start: Date, end: Date, color: UIColor) -> NSAttributedString {
        let digits: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: color]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10.5), .foregroundColor: color]
        func clock(_ date: Date) -> String {
            formatted(date, Calendar.current.component(.minute, from: date) == 0 ? "h" : "h:mm")
        }
        let text = NSMutableAttributedString(string: clock(start), attributes: digits)
        if formatted(start, "a") != formatted(end, "a") {
            text.append(NSAttributedString(string: formatted(start, "a"), attributes: small))
        }
        text.append(NSAttributedString(string: "–" + clock(end), attributes: digits))
        text.append(NSAttributedString(string: formatted(end, "a"), attributes: small))
        return text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: Self.barInset, y: Self.barInset, width: Self.barWidth, height: bounds.height - Self.barInset * 2)
        let textX = Self.barInset + Self.barWidth + 6
        let textWidth = bounds.width - textX - 8
        title.frame = CGRect(x: textX, y: 3, width: textWidth, height: 21)
        time.frame = CGRect(x: textX, y: 24, width: textWidth, height: 18)
    }
}
