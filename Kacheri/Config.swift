import UIKit

enum Config {
    /// The web app. Change this if the public hostname changes.
    static let radioURL = URL(string: "https://kacheri.nikolatesla.co.in")!
    /// Passport: Google sign-in hands the session back to the app through it (SignInHandoff).
    static let authURL = URL(string: "https://auth.nikolatesla.co.in")!
    /// Sign-in and the radio live under this domain; everything else opens outside the app.
    static let inAppDomain = "nikolatesla.co.in"
    /// Passport's app id for the handoff, and the scheme it sends the code back on (ridewave://auth?code=…).
    static let handoffApp = "ridewave"
    static let handoffScheme = "ridewave"

    /// Put the song and real buttons on the lock screen from the page's reports
    /// (window.RideWaveApp.playback → NowPlaying). If WebKit's own Media Session support
    /// already does this and the two fight over the lock screen, turn it off.
    static let nativeNowPlaying = true

    static let background = UIColor(red: 0x0F / 255.0, green: 0x13 / 255.0, blue: 0x22 / 255.0, alpha: 1)

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
}
