import AVFoundation
import UIKit

/// What a music app does when iOS takes the sound away. An incoming call, Siri, an alarm or another
/// app's audio (an Instagram reel, YouTube…) pauses Kacheri at once, and Kacheri then waits in the
/// background, silent, until that other sound is over, and only then carries on by itself.
/// Headphones out, AirPods out of the ears or a Bluetooth headset gone: pause, rather than carry on
/// from the phone's speaker.
///
/// The shell doesn't trust the page to stay quiet: while the sound belongs to someone else, every
/// media element in the web view is frozen (WKWebView.setAllMediaPlaybackSuspended), so nothing on
/// the page — whatever version of its code is running — can start playing over the call or the reel.
///
/// The page is told what's going on (window.__rwNative, public/js/native.js):
///   "interrupted"          the phone took the sound: pause, remember whether we were playing
///   "resume-interrupted"   the other sound is over: play on if we were playing
///   "unplugged"            the headphones went away: pause
@MainActor
final class AudioFocus {

    var onAction: ((String) -> Void)?
    /// After the sound was taken or came back: put Kacheri back on the lock screen (WebKit clears it).
    var onChange: (() -> Void)?
    /// Freeze (true) / thaw (false) all media in the web view, then call the completion.
    var suspendMedia: ((Bool, @escaping () -> Void) -> Void)?

    /// The sound was taken while we had it: give the music back once the phone is quiet again.
    private var waiting = false
    private var suspended = false
    private var quietTimer: Timer?
    private var quietChecks = 0
    private var watchedFor = 0
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            MainActor.assumeIsolated { self?.interruption(info) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        })
        // Opened again: the page's own buttons must work (a tap on play has to make sound). If we
        // were waiting for a call to end, we still resume when it does.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thaw() }
        })
        // The media server restarted (rare): the category is gone with it.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        })
    }

    /// A lock-screen / headset button was pressed: the listener decides now. Thaw, then do it.
    func handBack(then action: @escaping () -> Void) {
        waiting = false
        stopWatching()
        endTask()
        if suspended { setSuspended(false, then: action) } else { action() }
    }

    private func interruption(_ info: [AnyHashable: Any]?) {
        guard let info, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // "You were suspended" arrives late, when the app comes back: old news, not a call.
            if let r = info[AVAudioSessionInterruptionReasonKey] as? UInt,
               AVAudioSession.InterruptionReason(rawValue: r) == .appWasSuspended { return }
            waiting = true
            stopWatching()
            setSuspended(true)
            onAction?("interrupted")
            onChange?()
        case .ended:
            // The other side let go of the sound — but a reel may still be running (apps flip their
            // audio session on and off). Resume only once the phone is actually quiet.
            if waiting { watchForQuiet() }
        @unknown default:
            break
        }
    }

    // ───────── waiting for the other sound to finish ─────────

    private func watchForQuiet() {
        beginTask() // a few seconds of background time to look, even with the screen locked
        quietTimer?.invalidate()
        quietChecks = 0
        watchedFor = 0
        quietTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuiet() }
        }
    }

    private func checkQuiet() {
        let session = AVAudioSession.sharedInstance()
        let othersPlaying = session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
        quietChecks = othersPlaying ? 0 : quietChecks + 1
        watchedFor += 1
        if quietChecks >= 3 { // quiet for a good second: it's over
            stopWatching()
            resume()
        } else if watchedFor >= 50 {
            // Still busy after ~25 s. iOS won't let us keep watching from the background; we stay
            // paused (frozen), and the next "sound is free" from iOS, the lock screen's play button
            // or opening the app picks it up.
            stopWatching()
            endTask()
        }
    }

    private func stopWatching() {
        quietTimer?.invalidate()
        quietTimer = nil
    }

    private func resume() {
        guard waiting else { endTask(); return }
        waiting = false
        try? AVAudioSession.sharedInstance().setActive(true)
        setSuspended(false) { [weak self] in
            guard let self else { return }
            self.onAction?("resume-interrupted")
            self.onChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated { self?.endTask() }
            }
        }
    }

    /// Back in the app: let the page's buttons work. Doesn't start anything by itself.
    private func thaw() {
        guard suspended else { return }
        setSuspended(false)
    }

    private func setSuspended(_ on: Bool, then done: (() -> Void)? = nil) {
        suspended = on
        guard let suspendMedia else { done?(); return }
        suspendMedia(on) { done?() }
    }

    private func beginTask() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Kacheri waits for quiet") { [weak self] in
            MainActor.assumeIsolated {
                self?.stopWatching()
                self?.endTask()
            }
        }
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    private func routeChanged(_ reason: UInt?) {
        guard let reason, AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
        onAction?("unplugged")
    }
}
