import UIKit

/// Owns the connection to the Mac and hosts whichever mode is on screen.
final class RootViewController: UIViewController {
    private let server = PhoneServer()
    private let camera = CameraStreamer()
    private let updater = Updater()
    private let webcamControls = UIStackView()
    private let webcamStatus = UILabel()
    private let cameraSelection = UISegmentedControl(items: ["Front", "Back"])
    private var webcamRequested = false

    private func setupWebcamControls() {
        webcamControls.axis = .vertical
        webcamControls.spacing = 4
        webcamControls.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        webcamControls.layer.cornerRadius = 10
        webcamControls.isLayoutMarginsRelativeArrangement = true
        webcamControls.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        webcamStatus.font = .preferredFont(forTextStyle: .caption1)
        webcamStatus.adjustsFontForContentSizeCategory = true
        webcamStatus.numberOfLines = 0
        webcamStatus.textColor = .white
        cameraSelection.selectedSegmentIndex = 0
        cameraSelection.accessibilityLabel = "Webcam camera"
        cameraSelection.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        cameraSelection.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        cameraSelection.addTarget(self, action: #selector(selectWebcamCamera), for: .valueChanged)
        webcamControls.addArrangedSubview(webcamStatus)
        webcamControls.addArrangedSubview(cameraSelection)
        webcamControls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webcamControls)
        NSLayoutConstraint.activate([
            webcamControls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            webcamControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            webcamControls.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -16),
            webcamControls.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            cameraSelection.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        webcamControls.isHidden = true
        camera.onState = { [weak self] state in self?.showWebcamState(state) }
        showWebcamState(.stopped)
    }

    @objc private func selectWebcamCamera() {
        if webcamRequested { showWebcamState(.starting) }
        camera.selectCamera(back: cameraSelection.selectedSegmentIndex == 1)
    }

    private func showWebcamState(_ state: CameraStreamer.State) {
        guard connection != nil, UIApplication.shared.applicationState == .active else {
            webcamControls.isHidden = true
            return
        }
        webcamControls.isHidden = false
        let visibleState: CameraStreamer.State = webcamRequested ? state : .stopped
        switch visibleState {
        case .stopped: webcamStatus.text = "Webcam off"
        case .starting: webcamStatus.text = "Webcam starting…"
        case .live: webcamStatus.text = webcamRequested ? "● Webcam live" : "Webcam off"
        case .failed(let message): webcamStatus.text = "Webcam error: " + message
        }
        webcamStatus.accessibilityLabel = webcamStatus.text
        view.bringSubviewToFront(webcamControls)
    }
    private var connection: WireConnection?
    private var mode: PhoneMode?
    private let waiting = WaitingView()
    private var isWaiting = true
    private var welcomesUser = true

    /// The previous mode, kept on screen until the new one has something to show.
    private var outgoing: PhoneMode?
    private var queuedMode: ModeID?
    private var queuedPackets: [Data] = []
    private var queuedBytes = 0
    private var disconnectSnapshot: UIView?
    private var modeBackdrop: UIView?
    /// Goes up with every mode change, so anything still scheduled for an earlier change does nothing.
    private var modeGeneration = 0
    private var readyGeneration: Int?

    /// How long to hold for the new mode's first real picture before moving on anyway.
    private let readyTimeout: TimeInterval = 5

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        welcomesUser ? [.portrait, .landscape] : .landscape
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        waiting.frame = view.bounds
        waiting.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(waiting)
        waiting.setWelcome(welcomesUser)
        if welcomesUser {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.addObserver(self, selector: #selector(welcomeOrientationChanged),
                name: UIDevice.orientationDidChangeNotification, object: nil)
        }

        setupWebcamControls()

        server.onConnection = { [weak self] connection in self?.attach(connection) }
        updater.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkWelcomeOrientation()
    }

    @objc private func welcomeOrientationChanged() {
        if UIDevice.current.orientation.isLandscape { finishWelcome() }
    }

    private func checkWelcomeOrientation() {
        if UIDevice.current.orientation.isLandscape || view.window?.windowScene?.interfaceOrientation.isLandscape == true {
            finishWelcome()
        }
    }

    private func finishWelcome() {
        guard welcomesUser else { return }
        welcomesUser = false
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        waiting.setWelcome(false)
        // Reapply the existing landscape-only policy before any connected mode appears.
        UIViewController.attemptRotationToDeviceOrientation()
    }

    private func updateSleepPrevention() {
        let enabled = UserDefaults.standard.object(forKey: "sleepPrevention") as? Bool ?? true
        UIApplication.shared.isIdleTimerDisabled = enabled && !isWaiting && connection != nil
            && UIApplication.shared.applicationState == .active
    }

    func appBecameActive() {
        updateSleepPrevention()
        waiting.setAppActive(true)
        checkWelcomeOrientation()
        server.start()
    }

    func appWillResign() {
        // System overlays make us inactive without leaving the foreground. Keep the
        // USB session and visible mode intact; backgrounding owns teardown.
        waiting.setAppActive(false)
    }

    func appEnteredBackground() {
        webcamRequested = false
        webcamControls.isHidden = true
        waiting.setAppActive(false)
        server.stop()
        let old = connection
        connection = nil
        old?.close()
        camera.stop()
        backToWaiting()
    }

    private func attach(_ newConnection: WireConnection) {
        finishWelcome()
        connection?.close()
        camera.stop()
        if connection != nil { backToWaiting() }
        connection = newConnection
        webcamRequested = false
        camera.stop()
        showWebcamState(.stopped)

        newConnection.onMessage = { [weak self, weak newConnection] type, payload in
            guard let self, self.connection === newConnection else { return }
            self.received(type, payload)
        }
        newConnection.onClose = { [weak self, weak newConnection] in
            guard let self, self.connection === newConnection else { return }
            self.webcamRequested = false
            self.webcamControls.isHidden = true
            self.connection = nil
            self.camera.stop()
            self.backToWaiting()
        }
        camera.onPacket = { [weak newConnection] packet in
            newConnection?.send(.cameraVideo, packet.encoded(), droppable: !packet.isKeyframe) ?? false
        }
        newConnection.start()
        newConnection.send(.hello, Data([Wire.protocolVersion]))
    }

    private func backToWaiting() {
        modeLock.lock()
        queuedMode = nil
        queuedPackets.removeAll()
        queuedBytes = 0
        modeLock.unlock()
        // Preserve the exact visible frame if the cable goes away halfway through an effect.
        webcamControls.isHidden = true
        let snapshot = view.snapshotView(afterScreenUpdates: false)
        modeBackdrop?.removeFromSuperview()
        modeBackdrop = nil
        disconnectSnapshot?.removeFromSuperview()
        disconnectSnapshot = snapshot
        view.bringSubviewToFront(waiting)
        if let snapshot {
            snapshot.frame = view.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(snapshot, belowSubview: waiting)
        }
        isWaiting = true
        updateSleepPrevention()
        setMode(nil)
        waiting.showWaiting { [weak self] in
            guard let self else { return }
            self.disconnectSnapshot?.removeFromSuperview()
            self.disconnectSnapshot = nil
            self.dropOutgoing()
            self.drainQueuedMode()
        }
    }

    private func drainQueuedMode() {
        modeLock.lock()
        let next = queuedMode
        let packets = queuedPackets
        queuedMode = nil
        queuedPackets.removeAll()
        queuedBytes = 0
        modeLock.unlock()
        guard let next, connection != nil else { return }
        setMode(next)
        for packet in packets { mode?.receive(packet) }
    }

    private func modeReady(generation: Int) {
        guard generation == modeGeneration, connection != nil, readyGeneration != generation else { return }
        readyGeneration = generation
        if isWaiting {
            isWaiting = false
            updateSleepPrevention()
            if let dashboard = mode as? DashboardPhoneMode {
                waiting.revealDashboard(dashboard.view, backgrounds: dashboard.setWidgetBackgroundAlpha, colors: dashboard.setContentColorProgress) { [weak self] in self?.drainQueuedMode() }
            } else {
                waiting.reveal { [weak self] in self?.drainQueuedMode() }
            }
        } else if let old = outgoing, let new = mode {
            if let dashboard = old as? DashboardPhoneMode, new.id == .secondDisplay {
                let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
                blur.frame = view.bounds
                blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.insertSubview(blur, belowSubview: dashboard.view)
                modeBackdrop = blur
                waiting.dismissDashboard(dashboard.view, blur: blur,
                                         backgrounds: dashboard.setWidgetBackgroundAlpha) { [weak self] in
                    guard let self, generation == self.modeGeneration else { return }
                    self.modeBackdrop = nil
                    self.dropOutgoing()
                    self.drainQueuedMode()
                }
                return
            }
            if old.id == .secondDisplay, let dashboard = new as? DashboardPhoneMode,
               let snapshot = old.view.snapshotView(afterScreenUpdates: false) {
                let backdrop = UIView(frame: view.bounds)
                backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                backdrop.backgroundColor = .black
                snapshot.frame = backdrop.bounds
                snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                backdrop.addSubview(snapshot)
                let blur = UIVisualEffectView(effect: nil)
                blur.frame = backdrop.bounds
                blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                backdrop.addSubview(blur)
                view.addSubview(backdrop)
                old.view.isHidden = true
                modeBackdrop = backdrop
                waiting.revealDashboard(dashboard.view, over: backdrop, blur: blur,
                                        backgrounds: dashboard.setWidgetBackgroundAlpha,
                                        colors: dashboard.setContentColorProgress) { [weak self] in
                    guard let self, generation == self.modeGeneration else { return }
                    self.modeBackdrop = nil
                    self.dropOutgoing()
                    self.drainQueuedMode()
                }
                return
            }
            view.bringSubviewToFront(waiting)
            waiting.transition(forward: new.id.rawValue > old.id.rawValue, covered: { [weak self] in
                guard let self, generation == self.modeGeneration else { return }
                self.view.bringSubviewToFront(new.view)
                self.view.bringSubviewToFront(self.waiting)
                self.dropOutgoing()
            }, completion: { [weak self] in self?.drainQueuedMode() })
        }
    }

    private func dropOutgoing() {
        guard let old = outgoing else { return }
        outgoing = nil
        old.stop()
        old.view.layer.removeAllAnimations()
        old.view.removeFromSuperview()
    }

    /// Wire callbacks are serialized with lifecycle changes on the main queue.
    private func received(_ type: MessageType, _ payload: Data) {
        switch type {
        case .setMode:
            guard let raw = payload.first, let id = ModeID(rawValue: raw) else { return }
            setMode(id)
        case .setSleepPrevention:
            guard payload.count == 1, let value = payload.first, value <= 1 else { return }
            do {
                let enabled = value == 1
                UserDefaults.standard.set(enabled, forKey: "sleepPrevention")
                self.updateSleepPrevention()
            }
        case .setCamera:
            guard payload.count == 1, let value = payload.first, value <= 1 else { return }
            let on = value == 1
            do {
                self.webcamRequested = on
                self.showWebcamState(on ? .starting : .stopped)
                if on {
                    self.camera.start(orientation: self.interfaceOrientation())
                } else {
                    self.camera.stop()
                }
            }
        case .cameraKeyframeRequest:
            camera.forceKeyframe()
        case .modeData:
            modeLock.lock()
            if queuedMode != nil {
                // Bound buffering while an effect finishes. A newly started video mode requests a keyframe.
                if queuedBytes + payload.count <= 8 * 1024 * 1024 {
                    queuedPackets.append(payload)
                    queuedBytes += payload.count
                }
                modeLock.unlock()
                return
            }
            let current = mode
            modeLock.unlock()
            current?.receive(payload)
        case .hello, .cameraVideo:
            break
        }
    }

    private let modeLock = NSLock()

    private func setMode(_ id: ModeID?) {
        if let id, waiting.isTransitioning {
            modeLock.lock()
            if queuedMode != id {
                queuedPackets.removeAll()
                queuedBytes = 0
            }
            queuedMode = id
            modeLock.unlock()
            return
        }
        if let id, mode?.id == id { return }
        modeGeneration += 1
        readyGeneration = nil
        let generation = modeGeneration

        // Keep the visible outgoing mode when replacing a destination that is still loading.
        modeLock.lock()
        let pending = mode
        let old = outgoing ?? pending
        mode = nil
        modeLock.unlock()
        if outgoing != nil, let pending {
            pending.stop()
            pending.view.removeFromSuperview()
        }
        outgoing = old

        guard let id, let connection else {
            // The waiting cover owns cleanup after it has hidden the old screen.
            return
        }

        // Behind the waiting screen nobody can see the old mode, so there's nothing to transition from.
        if isWaiting { dropOutgoing() }

        let new = makePhoneMode(id)
        new.view.frame = view.bounds
        new.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let current = outgoing {
            view.insertSubview(new.view, belowSubview: current.view)
        } else {
            view.insertSubview(new.view, belowSubview: waiting)
        }
        new.onReady = { [weak self] in
            DispatchQueue.main.async { self?.modeReady(generation: generation) }
        }
        modeLock.lock()
        mode = new
        modeLock.unlock()
        new.start { [weak connection] data in
            connection?.send(.modeData, data)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + readyTimeout) { [weak self] in
            self?.modeReady(generation: generation)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if size.width > size.height { finishWelcome() }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.camera.setOrientation(self.interfaceOrientation())
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.bringSubviewToFront(webcamControls)
    }

    private func interfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }
}
