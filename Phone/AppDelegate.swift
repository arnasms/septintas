import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let controller = RootViewController()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        // Asked at launch, while you're looking at the phone, rather than in the middle of a call.
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        controller.appBecameActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = false
        controller.appWillResign()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        controller.appEnteredBackground()
    }
}
