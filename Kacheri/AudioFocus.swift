import AVFoundation
import UIKit

/// What every music app does when iOS takes the sound away. An incoming call, Siri, an alarm or
/// another app's audio (Instagram, YouTube…) pauses Kacheri at once, and the page must not start
/// itself again behind the phone's back. When the call ends and iOS says carrying on is right, the
/// music comes back by itself, screen locked or not. Headphones out, AirPods out of the ears or a
/// Bluetooth headset gone: pause, rather than carry on from the phone's speaker.
///
/// The page does the pausing and playing (window.__rwNative, public/js/native.js):
///   "interrupted"          the phone took the sound
///   "resume-interrupted"   it gave it back and says resume (a call ended)
///   "interruption-ended"   it gave it back without that (stay paused)
///   "unplugged"            the headphones went away
@MainActor
final class AudioFocus {

    var onAction: ((String) -> Void)?
    /// After the sound was taken or came back: put Kacheri back on the lock screen (WebKit clears it).
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var resumeTask: UIBackgroundTaskIdentifier = .invalid

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
        // The media server restarted (rare): the category is gone with it.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        })
    }

    private func interruption(_ info: [AnyHashable: Any]?) {
        guard let info, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // "You were suspended" arrives late, when the app comes back: old news, not a call.
            if let r = info[AVAudioSessionInterruptionReasonKey] as? UInt,
               AVAudioSession.InterruptionReason(rawValue: r) == .appWasSuspended { return }
            onAction?("interrupted")
            onChange?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) { resume() } else { onAction?("interruption-ended") }
        @unknown default:
            break
        }
    }

    private func resume() {
        // The app may be woken in the background just for this: ask for a few seconds to get the
        // page's audio going before iOS suspends us again.
        if resumeTask == .invalid {
            resumeTask = UIApplication.shared.beginBackgroundTask(withName: "Kacheri resume") { [weak self] in
                MainActor.assumeIsolated { self?.endResumeTask() }
            }
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        onAction?("resume-interrupted")
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.endResumeTask() }
        }
    }

    private func endResumeTask() {
        guard resumeTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(resumeTask)
        resumeTask = .invalid
    }

    private func routeChanged(_ reason: UInt?) {
        guard let reason, AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
        onAction?("unplugged")
    }
}
