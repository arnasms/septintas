import AppKit
import ServiceManagement
import EventKit

/// The menu bar item, plus the decisions about what should be running right now.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let link = PhoneLink()
    private let camera = VirtualCamera()
    private let decoder = CameraDecoder()
    private let calendarPermissionStore = EKEventStore()
    private var calendarRequestPending = false

    private var connection: WireConnection?
    private var mode: MacMode?
    private let modeLock = NSLock()

    private var cameraOn = false
    /// You turned the webcam off while an app still has it open, so don't turn it straight back on.
    private var cameraHeldOff = false
    private var cameraLastInUse = Date.distantPast
    private var loggedWebcamFrame = false
    /// An app holding the camera shouldn't turn the webcam straight back on as the Mac goes to sleep.
    private var asleep = false

    private var sleepPreventionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sleepPrevention") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sleepPrevention") }
    }

    private func sendSleepPrevention() {
        connection?.send(.setSleepPrevention, Data([sleepPreventionEnabled && !asleep ? 1 : 0]))
    }

    /// Also works when Launch Services starts the companion to handle the URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "septintas", url.host == "sleep-prevention",
                  url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
                  url.port == nil else { continue }
            switch url.path {
            case "/on": sleepPreventionEnabled = true
            case "/off": sleepPreventionEnabled = false
            default: continue
            }
            sendSleepPrevention()
        }
    }

    private var selectedMode: ModeID {
        get {
            let raw = UserDefaults.standard.integer(forKey: "mode")
            guard let byte = UInt8(exactly: raw), let mode = ModeID(rawValue: byte),
                  ModeID.selectableCases.contains(mode) else { return .secondDisplay }
            return mode
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: "mode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "mode") == nil {
            selectedMode = .secondDisplay
        }
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        decoder.onFrame = { [weak self] frame in
            guard let self else { return }
            if !self.loggedWebcamFrame {
                self.loggedWebcamFrame = true
                NSLog("i7: first webcam frame, %dx%d", CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
            }
            self.camera.enqueue(frame)
        }
        decoder.onNeedsKeyframe = { [weak self] in self?.connection?.send(.cameraKeyframeRequest) }

        link.onConnected = { [weak self] connection in self?.attach(connection) }
        link.onDisconnected = { [weak self] in self?.detach() }
        link.start()

        // macOS reports the camera being opened right away. The timer picks up a camera that
        // appears after launch, and anything the report misses.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkCameraDemand() }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.sendSleepPrevention()
            self?.setCamera(false)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.sendSleepPrevention()
            self?.checkCameraDemand()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
        mode?.stop()
    }

    // MARK: Connection

    private func attach(_ newConnection: WireConnection) {
        connection = newConnection
        newConnection.onMessage = { [weak self] type, payload in self?.received(type, payload) }
        newConnection.start()
        sendSleepPrevention()
        activate(selectedMode)
        if ProcessInfo.processInfo.environment["I7_TEST_CAMERA"] != nil {
            setCamera(true)
        }
        checkCameraDemand()
    }

    private func detach() {
        connection = nil
        deactivateMode()
        setCamera(false)
        cameraHeldOff = false
    }

    /// Runs on the connection's read thread.
    private func received(_ type: MessageType, _ payload: Data) {
        switch type {
        case .cameraVideo:
            guard let packet = VideoPacket(data: payload) else { return }
            decoder.decode(packet)
        case .modeData:
            modeLock.lock()
            let current = mode
            modeLock.unlock()
            current?.receive(payload)
        case .hello, .setMode, .setCamera, .cameraKeyframeRequest, .setSleepPrevention:
            break
        }
    }

    // MARK: Modes

    private func activate(_ id: ModeID) {
        guard let connection else { return }
        deactivateMode()
        // The phone gets its view ready first, so it's listening by the time data starts flowing.
        connection.send(.setMode, Data([id.rawValue]))
        let new = makeMacMode(id)
        modeLock.lock()
        mode = new
        modeLock.unlock()
        new.start { [weak connection] data, droppable in
            connection?.send(.modeData, data, droppable: droppable) ?? false
        }
    }

    private func deactivateMode() {
        modeLock.lock()
        let old = mode
        mode = nil
        modeLock.unlock()
        old?.stop()
    }

    // MARK: Webcam

    private func checkCameraDemand() {
        camera.watchUsage { [weak self] in self?.checkCameraDemand() }
        guard connection != nil, !cameraOn, !asleep else { return }
        if camera.isInUse {
            cameraLastInUse = Date()
            if !cameraHeldOff {
                // This also catches apps that open a camera for a moment just to look at it. Since the
                // webcam can't tell when an app lets go, the phone's camera stays on until it's turned off.
                setCamera(true)
            }
        } else if Date().timeIntervalSince(cameraLastInUse) >= 2 {
            // An app can drop the camera for a moment when its feed stops, so "turned off" only
            // ends once the camera has stayed free. Turning on never waits for this.
            cameraHeldOff = false
        }
    }

    private func setCamera(_ on: Bool) {
        guard on != cameraOn else { return }
        NSLog("i7: webcam %@", on ? "on" : "off")
        if on {
            guard connection != nil, camera.start() else { return }
            cameraOn = true
            connection?.send(.setCamera, Data([1]))
        } else {
            cameraOn = false
            connection?.send(.setCamera, Data([0]))
            camera.stop()
            decoder.reset()
        }
    }

    /// Keep the app identity stable; webcam state is shown in the menu.
    private func updateIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "iphone.landscape",
            accessibilityDescription: "septintas")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let phone = NSMenuItem(title: connection == nil ? "Waiting for the iPhone app…" : "iPhone connected", action: nil, keyEquivalent: "")
        phone.isEnabled = false
        menu.addItem(phone)
        menu.addItem(.separator())

        for id in ModeID.selectableCases {
            let item = NSMenuItem(title: id.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id.rawValue)
            item.state = id == selectedMode ? .on : .off
            menu.addItem(item)
        }

        let sizeItem = NSMenuItem(title: "Screen Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for size in ScreenSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = size == ScreenSize.saved ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        if !CGPreflightScreenCaptureAccess() {
            let item = NSMenuItem(title: "Allow Screen Recording…", action: #selector(askScreenRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !FileManager.default.isExecutableFile(atPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI") {
            let item = NSMenuItem(title: "Usage needs CodexBar — Setup…", action: #selector(showUsageSetup), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let title = CalendarSetup(authorization: EKEventStore.authorizationStatus(for: .event)).menuTitle {
            let item = NSMenuItem(title: title, action: #selector(showCalendarSetup), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if !camera.isAvailable {
            let item = NSMenuItem(title: "Webcam needs OBS — Setup…", action: #selector(showWebcamSetup), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let webcam = NSMenuItem(title: "Webcam", action: #selector(toggleCamera), keyEquivalent: "")
            webcam.target = self
            webcam.state = cameraOn ? .on : .off
            webcam.isEnabled = connection != nil
            menu.addItem(webcam)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let id = ModeID(rawValue: UInt8(sender.tag)), id != selectedMode else { return }
        selectedMode = id
        activate(id)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = ScreenSize(rawValue: raw) else { return }
        ScreenSize.saved = size
        (mode as? SecondDisplayMacMode)?.changeSize(size)
    }

    @objc private func askScreenRecording() {
        setupHelp("Allow Screen Recording", "Screen sharing needs Screen Recording access. In System Settings → Privacy & Security → Screen Recording (or Screen & System Audio Recording), enable septintas. Quit and reopen septintas if macOS asks, then reconnect the iPhone.")
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func setupHelp(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showUsageSetup() {
        setupHelp("Usage numbers need CodexBar", "Install CodexBar at /Applications/CodexBar.app with its bundled Contents/Helpers/CodexBarCLI executable, then open CodexBar and configure your providers. If CodexBar is already installed, update or reinstall it to restore the CLI. CodexBar can stay closed afterward. Reopen this menu to check again. The other dashboard widgets work without it.")
    }

    @objc private func showWebcamSetup() {
        setupHelp("Set up the webcam", "Install OBS Studio 30 or later in Applications and open it. Click Start Virtual Camera in Controls and follow the extension approval prompt. On macOS 14, check System Settings → Privacy & Security → Security; on newer macOS, check General → Login Items & Extensions for OBS’s camera or media extension. Once installed, stop the virtual camera and quit OBS so septintas can supply its frames. Reopen this menu to check again, then select OBS Virtual Camera in your video app. The display and dashboard work without OBS.")
    }

    @objc private func showCalendarSetup() {
        let setup = CalendarSetup(authorization: EKEventStore.authorizationStatus(for: .event))
        switch setup {
        case .request, .upgrade:
            guard !calendarRequestPending else { return }
            calendarRequestPending = true
            // Retain the store until EventKit finishes, even if the controller goes away.
            let store = calendarPermissionStore
            store.requestFullAccessToEvents { [weak self, store] granted, error in
                DispatchQueue.main.async {
                    _ = store
                    guard let self else { return }
                    self.calendarRequestPending = false
                    if let error {
                        self.setupHelp("Calendar access failed", error.localizedDescription)
                    } else if granted {
                        self.setupHelp("Calendar access allowed", "Reconnect the iPhone to refresh the calendar. Reopen this menu to check setup again.")
                    } else {
                        self.setupHelp("Calendar needs Full Access", "Open System Settings → Privacy & Security → Calendars and give septintas Full Access. Add Events Only cannot read upcoming events. After changing access, reconnect the iPhone to refresh the calendar, then reopen this menu to check again.")
                    }
                }
            }
        case .settings:
            setupHelp("Calendar needs Full Access", "Open System Settings → Privacy & Security → Calendars and give septintas Full Access. Add Events Only cannot read upcoming events. After changing access, reconnect the iPhone to refresh the calendar, then reopen this menu to check again.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        case .restricted:
            setupHelp("Calendar access is restricted", "macOS policy prevents Calendar access. Ask the administrator managing this Mac to allow Calendar access for septintas. The app cannot request permission while this restriction applies.")
        case .ready:
            break
        }
    }

    @objc private func toggleCamera() {
        let turningOff = cameraOn
        setCamera(!cameraOn)
        cameraHeldOff = turningOff
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}
