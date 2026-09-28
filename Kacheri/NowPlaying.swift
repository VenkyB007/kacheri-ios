import MediaPlayer
import UIKit
import WebKit

/// Lock screen, Control Center, headset and intercom buttons. It plays nothing itself
/// — the web view does — but it shows what the page says is playing and hands button presses back
/// to the page. The page keeps it fed through window.RideWaveApp.playback(json).
final class NowPlaying {

    /// What the page told us last: {active, playing, title, artist, art, prev, next, position, duration}.
    struct State {
        var active = false, playing = false, prev = false, next = false
        var title = "Kacheri", artist = ""
        var art: String?
        var position = 0.0, duration = 0.0

        init() {}

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            active = o["active"] as? Bool ?? false
            playing = o["playing"] as? Bool ?? false
            prev = o["prev"] as? Bool ?? false
            next = o["next"] as? Bool ?? false
            title = o["title"] as? String ?? "Kacheri"
            artist = o["artist"] as? String ?? ""
            art = o["art"] as? String
            position = (o["position"] as? NSNumber)?.doubleValue ?? 0
            duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        }
    }

    /// "play" | "pause" | "toggle" | "next" | "prev", for window.__rwNative.
    var onAction: ((String) -> Void)?
    /// Whether the page says music is playing, on every report.
    var onPlaying: ((Bool) -> Void)?
    /// The web view's cookies: the art proxy sits behind sign-in.
    var cookies: WKHTTPCookieStore?

    private var state = State()
    private var artwork: MPMediaItemArtwork?
    private var artURL: String?
    private var commandsReady = false

    func update(json: String) {
        guard let s = State(json: json) else { return }
        state = s
        onPlaying?(s.playing)
        if s.art != artURL {
            artURL = s.art
            artwork = nil
            loadArt(s.art)
        }
        setUpCommands()
        apply()
    }

    /// WebKit wipes the lock screen when the page's audio stops for a call or another app, and may
    /// do it a moment after the page tells us what's on: put Kacheri back, now and once more later.
    func reassert() {
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.apply() }
    }

    private func setUpCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        let send: (String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { action in
            { [weak self] _ in
                self?.onAction?(action)
                return .success
            }
        }
        c.playCommand.addTarget(handler: send("play"))
        c.pauseCommand.addTarget(handler: send("pause"))
        c.togglePlayPauseCommand.addTarget(handler: send("toggle"))
        c.stopCommand.addTarget(handler: send("pause"))
        c.nextTrackCommand.addTarget(handler: send("next"))
        c.previousTrackCommand.addTarget(handler: send("prev"))
        // No scrubbing: in a ride the host's timeline is everyone's.
        c.changePlaybackPositionCommand.isEnabled = false
    }

    private func apply() {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = state.active && state.next
        c.previousTrackCommand.isEnabled = state.active && state.prev
        guard state.active else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPMediaItemPropertyAlbumTitle: "Kacheri",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0,
        ]
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArt(_ url: String?) {
        guard let url, let u = URL(string: url), u.scheme == "https" else { return }
        let fetch: ([HTTPCookie]) -> Void = { [weak self] cookies in
            let config = URLSessionConfiguration.ephemeral
            cookies.forEach { config.httpCookieStorage?.setCookie($0) }
            var req = URLRequest(url: u)
            req.timeoutInterval = 15
            let session = URLSession(configuration: config)
            session.dataTask(with: req) { data, response, _ in
                let image = (response as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(UIImage.init(data:)) : nil
                DispatchQueue.main.async {
                    guard let self, self.artURL == url, let image else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.apply()
                }
            }.resume()
            session.finishTasksAndInvalidate()
        }
        if let cookies { cookies.getAllCookies(fetch) } else { fetch([]) }
    }
}
