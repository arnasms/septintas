import UIKit

/// A widget owns its entire slot, including internal layout and any live data it retains.
protocol DashboardWidget: AnyObject {
    var view: UIView { get }
    func apply(_ update: DashboardUpdate)
    func tick()
    func setWidgetBackgroundAlpha(_ alpha: CGFloat)
    var contentColorProgress: CGFloat { get set }
}

extension DashboardWidget {
    func apply(_ update: DashboardUpdate) {}
    func tick() {}
    var contentColorProgress: CGFloat {
        get { 1 }
        set {}
    }
}

struct DashboardWidgetRegistration {
    let id: String
    let title: String
    let make: () -> DashboardWidget
}

/// Three recycled pages keep UIKit's native finger tracking and settling cheap on iPhone 7.
/// Each slot has its own widget instances, so duplicate selections never share a UIView.
final class DashboardSlot: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let registrations = dashboardWidgets
    private lazy var widgets = registrations.map { $0.make() }
    private let preferenceKey: String
    private var index: Int
    private var arrangedIndex: Int?
    private var arrangedSize = CGSize.zero
    var contentColorProgress: CGFloat = 1 {
        didSet { widgets.forEach { $0.contentColorProgress = contentColorProgress } }
    }

    init(defaultID: String, key: String) {
        preferenceKey = "dashboard.widget." + key
        let saved = UserDefaults.standard.string(forKey: preferenceKey) ?? defaultID
        index = dashboardWidgets.firstIndex { $0.id == saved }
            ?? dashboardWidgets.firstIndex { $0.id == defaultID } ?? 0
        super.init(frame: .zero)
        clipsToBounds = true
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bounces = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        addSubview(scroll)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next widget", target: self, selector: #selector(nextWidget)),
            UIAccessibilityCustomAction(name: "Previous widget", target: self, selector: #selector(previousWidget))
        ]
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wrapped(_ value: Int) -> Int {
        (value + registrations.count) % registrations.count
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        guard arrangedIndex != index || arrangedSize != bounds.size else { return }
        arrangedIndex = index
        arrangedSize = bounds.size
        // Reparenting is unnecessary: keep the same three views alive, including album palettes.
        widgets.forEach { $0.view.isHidden = true }
        for delta in -1...1 {
            let widget = widgets[wrapped(index + delta)]
            widget.view.isHidden = false
            if widget.view.superview == nil { scroll.addSubview(widget.view) }
            widget.view.frame = CGRect(x: 0, y: CGFloat(delta + 1) * bounds.height,
                                       width: bounds.width, height: bounds.height)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: bounds.height * 3)
        scroll.contentOffset = CGPoint(x: 0, y: bounds.height)
        accessibilityLabel = registrations[index].title
    }

    func select(_ id: String, persist: Bool = true) {
        guard let selected = registrations.firstIndex(where: { $0.id == id }) else { return }
        index = selected
        if persist { UserDefaults.standard.set(id, forKey: preferenceKey) }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func settle() {
        guard bounds.height > 0 else { return }
        let page = Int((scroll.contentOffset.y / bounds.height).rounded())
        if page != 1 { select(registrations[wrapped(index + (page < 1 ? -1 : 1))].id) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }
    @objc private func nextWidget() -> Bool {
        select(registrations[wrapped(index + 1)].id)
        return true
    }
    @objc private func previousWidget() -> Bool {
        select(registrations[wrapped(index - 1)].id)
        return true
    }
    func apply(_ update: DashboardUpdate) { widgets.forEach { $0.apply(update) } }
    func tick() { widgets.forEach { $0.tick() } }
    func setWidgetBackgroundAlpha(_ alpha: CGFloat) {
        widgets.forEach { $0.setWidgetBackgroundAlpha(alpha) }
    }
}

/// Entirely local: no network, Mac polling or image work.
final class ClockDashboardWidget: UIView, DashboardWidget {
    var view: UIView { self }
    private let surface = UIView()
    private let time = UILabel()
    private let date = UILabel()
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private var lastMinute: Int?

    init() {
        super.init(frame: .zero)
        surface.backgroundColor = UIColor(white: 0.065, alpha: 1)
        surface.layer.cornerRadius = 16
        surface.layer.cornerCurve = .continuous
        addSubview(surface)
        time.font = .monospacedDigitSystemFont(ofSize: 64, weight: .light)
        time.textColor = .white
        time.adjustsFontSizeToFitWidth = true
        time.minimumScaleFactor = 0.5
        date.font = .systemFont(ofSize: 18, weight: .medium)
        date.textColor = UIColor(white: 0.65, alpha: 1)
        date.adjustsFontSizeToFitWidth = true
        date.minimumScaleFactor = 0.7
        for label in [time, date] {
            label.textAlignment = .center
            addSubview(label)
        }
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEE MMMMd")
        tick()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        time.frame = CGRect(x: 16, y: bounds.midY - 56, width: bounds.width - 32, height: 78)
        date.frame = CGRect(x: 16, y: bounds.midY + 30, width: bounds.width - 32, height: 28)
    }
    func tick() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard minute != lastMinute else { return }
        lastMinute = minute
        time.text = timeFormatter.string(from: now)
        date.text = dateFormatter.string(from: now)
    }
    func setWidgetBackgroundAlpha(_ alpha: CGFloat) { surface.alpha = alpha }
}
