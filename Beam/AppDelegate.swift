import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // .playback (with UIBackgroundModes=audio): the web view's music keeps going with the
        // screen locked and ignores the silent switch, like a music app. Not activated here, so
        // opening Beam doesn't stop whatever else was playing until Beam itself plays.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        return true
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = Config.background
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
