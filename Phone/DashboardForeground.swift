import UIKit

/// Captures the dashboard's foreground colours, preserving live label text during the entrance.
final class DashboardForeground {
    private(set) var progress: CGFloat = 1
    private var updates: [(CGFloat) -> Void] = []

    func setProgress(_ progress: CGFloat, in root: UIView) {
        self.progress = progress
        if updates.isEmpty, progress < 1 {
            root.layoutIfNeeded()
            capture(root)
        }
        updates.forEach { $0(progress) }
        if progress >= 1 { updates.removeAll() }
    }

    private func capture(_ view: UIView) {
        if let label = view as? UILabel {
            let normal = label.textColor ?? .white
            var foregrounds: [(NSRange, UIColor)] = []
            if let text = label.attributedText {
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    foregrounds.append((range, value as? UIColor ?? normal))
                }
            }
            updates.append { [weak label] progress in
                guard let label else { return }
                let current = label.attributedText
                label.textColor = Self.blend(normal, progress)
                if !foregrounds.isEmpty, let current {
                    let text = NSMutableAttributedString(attributedString: current)
                    // Keep the original runs even when a white phase visually merges adjacent colours.
                    for (index, run) in foregrounds.enumerated() {
                        let start = min(run.0.location, text.length)
                        let end = index == foregrounds.count - 1 ? text.length : min(NSMaxRange(run.0), text.length)
                        if end > start {
                            text.addAttribute(.foregroundColor, value: Self.blend(run.1, progress),
                                              range: NSRange(location: start, length: end - start))
                        }
                    }
                    label.attributedText = text
                }
            }
        }
        // Progress tracks and calendar bars; leave artwork and tile surfaces intact.
        if !(view is UIImageView), view.bounds.height <= 10, view.bounds.height > 0,
           let normal = view.backgroundColor, normal.cgColor.alpha > 0 {
            updates.append { [weak view] progress in view?.backgroundColor = Self.blend(normal, progress) }
        }
        for layer in view.layer.sublayers ?? [] {
            if let shape = layer as? CAShapeLayer, let color = shape.fillColor {
                let normal = UIColor(cgColor: color)
                updates.append { [weak shape] progress in shape?.fillColor = Self.blend(normal, progress).cgColor }
            }
        }
        view.subviews.forEach(capture)
    }

    private static func blend(_ color: UIColor, _ progress: CGFloat) -> UIColor {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Keep dark tracks subdued so their white foreground fills remain distinguishable.
        let isTrack = max(r, g, b) < 0.3
        let whiteAlpha: CGFloat = isTrack ? a * 0.25 : a
        return UIColor(red: 1 + (r - 1) * progress, green: 1 + (g - 1) * progress,
                       blue: 1 + (b - 1) * progress, alpha: whiteAlpha + (a - whiteAlpha) * progress)
    }
}
