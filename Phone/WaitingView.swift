import MetalKit
import UIKit

/// Sits on top of everything until the Mac connects, then blows itself open to show what's underneath.
final class WaitingView: UIView, MTKViewDelegate {
    static let fadeInDuration: TimeInterval = 3.0

    private struct Uniforms {
        var time: Float
        var aspect: Float
        var impact: Float
        var warmth: Float
        var effect: Float
    }

    private let metal = MTKView()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let title = UILabel()
    private let subtitle = UILabel()
    private var showsWelcome = false
    private let started = CACurrentMediaTime()
    private var impactAt: CFTimeInterval?
    private var effect: Float = 0
    private var duration: CFTimeInterval = 1.05
    private var midpoint: (() -> Void)?
    var isTransitioning: Bool { finish != nil }
    private var finish: (() -> Void)?
    private var isOnScreen = true
    private var appActive = true
    private var revealGeneration = 0
    private var colorTween: DashboardColorTween?
    private var connectedAt: CFTimeInterval?
    private var entranceCleanup: (() -> Void)?

    /// Normalised shader progress stretches the original impact without changing its pattern.
    private let impactDuration: CFTimeInterval = 1.45 / 3.0
    private let idleFramesPerSecond = 30
    private let impactFramesPerSecond = 60

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        setUpMetal()

        title.text = "Waiting for your Mac"
        title.textAlignment = .center
        title.textColor = .white
        title.font = .systemFont(ofSize: 36, weight: .semibold)
        title.layer.shadowColor = UIColor(red: 0.45, green: 0.05, blue: 0.1, alpha: 1).cgColor
        title.layer.shadowOpacity = 0.35
        title.layer.shadowRadius = 10
        title.layer.shadowOffset = .zero
        addSubview(title)
        subtitle.text = "Rotate your iPhone to landscape."
        subtitle.font = .systemFont(ofSize: 18)
        subtitle.textColor = .white
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.isHidden = true
        addSubview(subtitle)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUpMetal() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: waitingShaderSource, options: nil),
              let vertex = library.makeFunction(name: "waitingVertex"),
              let fragment = library.makeFunction(name: "waitingFragment") else {
            NSLog("i7: waiting screen effect unavailable")
            return
        }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = vertex
        description.fragmentFunction = fragment
        description.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: description)
        queue = device.makeCommandQueue()
        guard pipeline != nil, queue != nil else { return }

        metal.device = device
        metal.colorPixelFormat = .bgra8Unorm
        metal.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metal.isOpaque = false
        metal.backgroundColor = .clear
        metal.delegate = self
        metal.preferredFramesPerSecond = idleFramesPerSecond
        // Half resolution is plenty for soft colour, and this screen can sit here for hours.
        metal.contentScaleFactor = 1
        addSubview(metal)
        // From here on the shader paints everything, including its own transparency.
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metal.frame = bounds
        if showsWelcome {
            let width = max(0, bounds.width - 48)
            let titleSize = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let subtitleSize = subtitle.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let top = (bounds.height - titleSize.height - 16 - subtitleSize.height) / 2
            title.frame = CGRect(x: 24, y: top, width: width, height: titleSize.height)
            subtitle.frame = CGRect(x: 24, y: title.frame.maxY + 16, width: width, height: subtitleSize.height)
        } else {
            title.frame = bounds
        }
    }

    func setWelcome(_ welcome: Bool) {
        showsWelcome = welcome
        title.text = welcome ? "Welcome to septintas" : "Waiting for your Mac"
        title.numberOfLines = welcome ? 0 : 1
        subtitle.isHidden = !welcome
        setNeedsLayout()
    }

    /// One second to black, then two seconds for the field; the title starts a second later.
    func showWaiting(completion: @escaping () -> Void = {}) {
        revealGeneration += 1
        let generation = revealGeneration
        entranceCleanup?()
        entranceCleanup = nil
        layer.removeAllAnimations()
        title.layer.removeAllAnimations()
        metal.layer.removeAllAnimations()
        connectedAt = nil
        impactAt = nil
        midpoint = nil
        finish = completion
        isOnScreen = true
        isHidden = false
        effect = 2
        backgroundColor = .black
        alpha = 0
        title.alpha = 0
        metal.alpha = 0
        metal.isHidden = pipeline == nil
        metal.isPaused = !appActive
        metal.preferredFramesPerSecond = idleFramesPerSecond
        UIView.animate(withDuration: 1, delay: 0, options: [.curveEaseInOut], animations: {
            self.alpha = 1
        }) { _ in
            guard generation == self.revealGeneration else { return }
            UIView.animate(withDuration: 2, delay: 0, options: [.curveEaseInOut], animations: {
                self.metal.alpha = 1
            })
            UIView.animate(withDuration: 1, delay: 1, options: [.curveEaseInOut], animations: {
                self.title.alpha = 1
            }) { _ in
                guard generation == self.revealGeneration else { return }
                let done = self.finish
                self.finish = nil
                done?()
            }
        }
    }

    /// Quickly blend the black palette stop back to amber before the entrance begins.
    private func warmUp(_ next: @escaping () -> Void) {
        revealGeneration += 1
        let generation = revealGeneration
        connectedAt = CACurrentMediaTime()
        finish = {} // Keep incoming mode changes queued during the palette blend too.
        metal.isPaused = !appActive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.revealGeneration else { return }
            next()
        }
    }

    func reveal(completion: @escaping () -> Void) {
        warmUp { [weak self] in
            guard let self else { return }
            self.run(effect: 0, duration: self.impactDuration, midpoint: nil, completion: completion)
            if !UIAccessibility.isReduceMotionEnabled {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
    }

    /// Dashboard widgets grow into place over the live waiting field; only then does it fade away.
    func revealDashboard(_ content: UIView, backgrounds: @escaping (CGFloat) -> Void, colors: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        warmUp { [weak self] in self?.beginDashboardEntrance(content, backgrounds: backgrounds, colors: colors, completion: completion) }
    }

    /// Reuse the dashboard entrance over a frozen desktop instead of the waiting field.
    func revealDashboard(_ content: UIView, over backdrop: UIView, blur: UIVisualEffectView,
                         backgrounds: @escaping (CGFloat) -> Void, colors: @escaping (CGFloat) -> Void,
                         completion: @escaping () -> Void) {
        revealGeneration += 1
        let generation = revealGeneration
        finish = {}
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22,
                       delay: 0, options: [.curveEaseInOut], animations: {
            blur.effect = UIBlurEffect(style: .dark)
        }) { [weak self] _ in
            guard let self, generation == self.revealGeneration else { return }
            self.beginDashboardEntrance(content, backdrop: backdrop, backgrounds: backgrounds, colors: colors, completion: completion)
        }
    }

    /// Pull the dashboard away, then bring the live desktop underneath back into focus.
    func dismissDashboard(_ content: UIView, blur: UIVisualEffectView,
                          backgrounds: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        revealGeneration += 1
        let generation = revealGeneration
        entranceCleanup?()
        finish = completion
        let originalBackground = content.backgroundColor
        content.backgroundColor = .clear
        entranceCleanup = {
            blur.removeFromSuperview()
            content.layer.removeAllAnimations()
            content.alpha = 1
            content.transform = .identity
            content.backgroundColor = originalBackground
            backgrounds(1)
        }
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reducedMotion ? 0.15 : 0.18) { backgrounds(0) }
        UIView.animate(withDuration: reducedMotion ? 0.15 : 0.3,
                       delay: 0, options: [.curveEaseInOut], animations: {
            content.alpha = 0
            content.transform = reducedMotion ? .identity : CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { [weak self] _ in
            guard let self, generation == self.revealGeneration else { return }
            UIView.animate(withDuration: reducedMotion ? 0.15 : 0.25,
                           delay: 0, options: [.curveEaseOut], animations: {
                blur.effect = nil
            }) { [weak self] _ in
                guard let self, generation == self.revealGeneration else { return }
                // Remove the outgoing mode before restoring its appearance during cleanup.
                content.removeFromSuperview()
                self.entranceCleanup?()
                self.entranceCleanup = nil
                let done = self.finish
                self.finish = nil
                done?()
            }
        }
    }

    private func beginDashboardEntrance(_ content: UIView, backdrop: UIView? = nil, backgrounds: @escaping (CGFloat) -> Void, colors: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        revealGeneration += 1
        let generation = revealGeneration
        entranceCleanup?()
        entranceCleanup = nil
        layer.removeAllAnimations()
        title.layer.removeAllAnimations()
        impactAt = nil
        midpoint = nil
        finish = completion
        isOnScreen = backdrop == nil
        isHidden = backdrop != nil
        alpha = 1
        metal.isPaused = backdrop != nil || !appActive
        metal.preferredFramesPerSecond = impactFramesPerSecond
        backgrounds(0)
        colors(0)
        let originalBackground = content.backgroundColor
        content.backgroundColor = .clear
        content.alpha = 0
        content.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(scaleX: 0.9, y: 0.9)
        entranceCleanup = { [weak self] in
            backdrop?.removeFromSuperview()
            self?.colorTween?.stop()
            self?.colorTween = nil
            colors(1)
            content.layer.removeAllAnimations()
            content.transform = .identity
            content.alpha = 1
            content.backgroundColor = originalBackground
            backgrounds(1)
        }
        superview?.bringSubviewToFront(content)
        UIView.animate(withDuration: 0.18) { self.title.alpha = 0 }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.25 : 0.9,
                       delay: 0.08, options: [.curveEaseOut, .allowUserInteraction], animations: {
            content.transform = .identity
            content.alpha = 1
        }) { _ in
            guard generation == self.revealGeneration else { return }
            // Begin widget surfaces and their foreground colours while the field is still visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, generation == self.revealGeneration else { return }
                UIView.animate(withDuration: 0.7, delay: 0, options: [.curveEaseInOut]) { backgrounds(1) }
                self.colorTween = DashboardColorTween(duration: 0.7, update: colors)
            }
            UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut], animations: {
                self.alpha = 0
                backdrop?.alpha = 0
            }) { _ in
                guard generation == self.revealGeneration else { return }
                self.entranceCleanup?()
                self.entranceCleanup = nil
                let done = self.finish
                self.finish = nil
                self.finishReveal()
                self.superview?.bringSubviewToFront(self)
                done?()
            }
        }
    }

    /// Covers the old mode completely before swapping it, then clears in the same direction.
    func transition(forward: Bool, covered: @escaping () -> Void, completion: @escaping () -> Void) {
        run(effect: forward ? 1 : -1, duration: 0.9, midpoint: covered, completion: completion)
    }

    private func run(effect: Float, duration: TimeInterval, midpoint: (() -> Void)?,
                     completion: @escaping () -> Void) {
        revealGeneration += 1
        let generation = revealGeneration
        entranceCleanup?()
        entranceCleanup = nil
        layer.removeAllAnimations()
        title.layer.removeAllAnimations()
        self.effect = effect
        self.duration = duration
        self.midpoint = midpoint
        finish = completion
        isOnScreen = true
        isHidden = false
        alpha = 1
        title.alpha = effect == 0 ? 1 : 0
        metal.isPaused = !appActive
        metal.preferredFramesPerSecond = impactFramesPerSecond
        impactAt = CACurrentMediaTime()

        guard pipeline != nil, !UIAccessibility.isReduceMotionEnabled else {
            // Crossfade fallback also swaps only under an opaque cover.
            impactAt = nil
            metal.isPaused = true
            metal.isHidden = true
            backgroundColor = UIColor(red: 1, green: 0.54, blue: 0, alpha: 1)
            alpha = effect == 0 ? 1 : 0
            UIView.animate(withDuration: 0.18, animations: { self.alpha = 1 }) { _ in
                guard generation == self.revealGeneration else { return }
                self.midpoint?()
                self.midpoint = nil
                UIView.animate(withDuration: 0.18, animations: {
                    self.alpha = effect == 2 ? 1 : 0
                    self.title.alpha = effect == 2 ? 1 : 0
                }) { _ in
                    guard generation == self.revealGeneration else { return }
                    self.completeTransition()
                }
            }
            return
        }
        metal.isHidden = false
        backgroundColor = .clear
        if effect == 0 {
            UIView.animate(withDuration: 0.12) { self.title.alpha = 0 }
        }
    }

    private func completeTransition() {
        let done = finish
        finish = nil
        midpoint?()
        midpoint = nil
        impactAt = nil
        if effect == 2 {
            title.alpha = 1
            metal.preferredFramesPerSecond = idleFramesPerSecond
            // Restore the live field after a reduced-motion crossfade.
            if pipeline != nil {
                metal.isHidden = false
                backgroundColor = .clear
                metal.isPaused = !appActive
            }
        } else {
            finishReveal()
        }
        done?()
    }

    /// iOS doesn't allow drawing with Metal while the app is in the background.
    func setAppActive(_ active: Bool) {
        appActive = active
        metal.isPaused = !active || !isOnScreen
    }

    private func finishReveal() {
        isOnScreen = false
        isHidden = true
        metal.isPaused = true
        alpha = 1
        impactAt = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if let impactAt {
            let elapsed = now - impactAt
            if elapsed >= duration * 0.5, let covered = midpoint {
                midpoint = nil
                covered()
            }
            if elapsed >= duration {
                completeTransition()
                return
            }
            if effect == 2 { title.alpha = CGFloat(max(0, (elapsed / duration - 0.65) / 0.35)) }
        }
        guard let pipeline, let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        var uniforms = Uniforms(
            time: Float(now - started),
            aspect: Float(size.width / max(size.height, 1)),
            impact: impactAt.map { Float((now - $0) / duration) } ?? -1,
            warmth: connectedAt.map {
                let t = min(1, max(0, Float((now - $0) / 0.25)))
                return t * t * (3 - 2 * t)
            } ?? 0,
            effect: effect)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// UILabel attributed colours need per-frame interpolation; UIView animations do not tween them.
private final class DashboardColorTween: NSObject {
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private let duration: CFTimeInterval
    private let update: (CGFloat) -> Void

    init(duration: CFTimeInterval, update: @escaping (CGFloat) -> Void) {
        self.duration = duration
        self.update = update
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        let t = min(1, max(0, (CACurrentMediaTime() - start) / duration))
        update(CGFloat(t * t * (3 - 2 * t)))
        if t >= 1 { stop() }
    }

    func stop() { link?.invalidate(); link = nil }
}
