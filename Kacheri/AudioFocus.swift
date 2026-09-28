import AVFoundation
import CallKit
import UIKit

/// What a music app does when iOS takes the sound away. An incoming or outgoing call, Siri, an alarm:
/// Kacheri pauses at once, waits in the background, and carries on by itself once the call is over.
/// Headphones out, AirPods out of the ears or a Bluetooth headset gone: pause, rather than carry on
/// from the phone's speaker. (Another app's sound — an Instagram reel — the page handles itself:
/// WebKit pauses our song, and keepalive.js / native.js hold everything until the sound is free.)
///
/// Why the shell needs its own audio: WKWebView plays from WebKit's own process, and it is *that*
/// process iOS interrupts. When a call has paused it, iOS suspends it, and at the end of the call
/// there is nobody awake to resume — so the music never comes back. Spotify gets woken because its
/// audio session was the one interrupted. So while Kacheri plays, the shell keeps an audio session of
/// its own open with a silent loop ("the anchor"). It mixes with others, so it never stops another
/// app, but a call interrupts it like any music app, and iOS wakes us when the call ends. CallKit's
/// call observer tells us the same thing independently (ringing, dialling, hung up).
///
/// The page stays silent through the call by itself (keepalive.js holds everything). The shell
/// does NOT freeze the web view's media (setAllMediaPlaybackSuspended): overlapping iOS's own call
/// interruption, that left WebKit refusing every play() — even taps — until the app restarted.
///
/// The page is told what's going on (window.__rwNative, public/js/native.js):
///   "interrupted"          a call (or Siri…) took the sound: pause, remember whether we were playing
///   "resume-interrupted"   it's over and the phone is quiet: play on if we were playing
///   "unplugged"            the headphones went away: pause
///   "log:…"                notes for the page's audio log
@MainActor
final class AudioFocus {

    var onAction: ((String) -> Void)?
    /// After the sound was taken or came back: put Kacheri back on the lock screen (WebKit clears it).
    var onChange: (() -> Void)?
    /// The sound was taken while we had it: give the music back once the phone is quiet again.
    private var waiting = false
    private var quietTimer: Timer?
    private var quietChecks = 0
    private var watchedFor = 0
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    private let calls = CXCallObserver()
    private var callWatch: CallWatch?
    private var onCall = false

    private var anchor: AVAudioPlayer?
    private var pagePlaying = false
    private var lastPlayingAt = Date.distantPast
    private var anchorStop: DispatchWorkItem?

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
        // Opened again: a call may have ended while we were suspended.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.callsChanged() }
        })
        // The media server restarted (rare): everything audio is gone with it.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.anchor = nil
                if self?.pagePlaying == true { self?.startAnchor() }
            }
        })
        let watch = CallWatch { [weak self] in MainActor.assumeIsolated { self?.callsChanged() } }
        callWatch = watch
        calls.setDelegate(watch, queue: nil) // nil: the main queue
    }

    /// What the page last said (window.RideWaveApp.playback): the anchor runs while music plays.
    func pageState(playing: Bool) {
        if playing { lastPlayingAt = Date() }
        guard playing != pagePlaying else { return }
        pagePlaying = playing
        anchorStop?.cancel()
        anchorStop = nil
        if playing {
            startAnchor()
        } else if !waiting {
            // Paused by the listener: keep the anchor a while (lock screen / headset play still
            // works instantly), then let the phone rest.
            let stop = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stopAnchor() } }
            anchorStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60, execute: stop)
        }
    }

    /// A lock-screen / headset button was pressed: the listener decides now.
    func handBack(then action: @escaping () -> Void) {
        waiting = false
        stopWatching()
        endTask()
        action()
    }

    // ───────── the anchor: our own audio session, so a call interrupts *us* ─────────

    private func startAnchor() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixes with others: it never stops another app, and never Kacheri's own music.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            note("anchor-session-failed \(error.localizedDescription)")
        }
        if anchor == nil {
            anchor = try? AVAudioPlayer(data: Self.silence)
            anchor?.numberOfLoops = -1
            anchor?.prepareToPlay()
        }
        if anchor?.isPlaying == false {
            let ok = anchor?.play() ?? false
            note("anchor-play \(ok)")
        }
    }

    private func stopAnchor() {
        guard let anchor, anchor.isPlaying else { return }
        anchor.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
        note("anchor-stop")
    }

    /// One second of 16-bit mono silence as a WAV file.
    private static let silence: Data = {
        let rate: UInt32 = 8000, bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }()

    // ───────── calls ─────────

    private func callsChanged() {
        let now = calls.calls.contains { !$0.hasEnded }
        guard now != onCall else { return }
        onCall = now
        note(now ? "call-started" : "call-ended")
        if now {
            // Only if Kacheri was playing (or was, a moment ago: the ring may have paused it first).
            guard pagePlaying || Date().timeIntervalSince(lastPlayingAt) < 5 || waiting else { return }
            takenAway()
        } else if waiting {
            watchForQuiet()
        }
    }

    private func interruption(_ info: [AnyHashable: Any]?) {
        guard let info, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // "You were suspended" arrives late, when the app comes back: old news, not a call.
            if let r = info[AVAudioSessionInterruptionReasonKey] as? UInt,
               AVAudioSession.InterruptionReason(rawValue: r) == .appWasSuspended { return }
            note("interruption-began")
            guard pagePlaying || Date().timeIntervalSince(lastPlayingAt) < 5 || waiting else { return }
            takenAway()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            note("interruption-ended resume=\(options.contains(.shouldResume)) onCall=\(onCall)")
            callsChanged()
            // Still on a call (a second one, or on hold): keep waiting. Otherwise, once it's quiet.
            if waiting && !onCall { watchForQuiet() }
        @unknown default:
            break
        }
    }

    private func takenAway() {
        waiting = true
        stopWatching()
        onAction?("interrupted")
        onChange?()
    }

    // ───────── waiting for the phone to be quiet ─────────

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
        quietChecks = (othersPlaying || onCall) ? 0 : quietChecks + 1
        watchedFor += 1
        if quietChecks >= 3 { // quiet for a good second: it's over
            stopWatching()
            resume()
        } else if watchedFor >= 50 {
            // Still busy after ~25 s: stay paused (frozen). The next "call ended", the lock
            // screen's play button or opening the app picks it up.
            note("still-busy")
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
        note("resume")
        // The page first; the anchor restarts once the page reports it's playing (pageState).
        pagePlaying = false
        onAction?("resume-interrupted")
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.endTask() }
        }
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
        note("unplugged")
        onAction?("unplugged")
    }

    private func note(_ s: String) {
        onAction?("log:\(s)")
    }
}

/// CXCallObserverDelegate has to be an NSObject; this one just says "something changed".
private final class CallWatch: NSObject, CXCallObserverDelegate {
    private let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) { changed() }
}
