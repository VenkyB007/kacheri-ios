import UIKit
import WebKit

/// WKWebView shell around the Kacheri web app, plus what a web page can't do on its own: keep the
/// music going in the pocket (background audio mode, AppDelegate), real lock-screen and headset
/// buttons (NowPlaying), and Google sign-in, which Google refuses inside web views
/// (SignInHandoff). The page reports what is playing through window.RideWaveApp.playback(json);
/// button presses come back through window.__rwNative(action) — the same bridge as Android.
final class WebViewController: UIViewController {

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let offline = UIStackView()
    private var progressWatch: NSKeyValueObservation?
    private let nowPlaying = NowPlaying()
    private let signIn = SignInHandoff()

    /// window.RideWaveApp for the page (public/js/native.js). No update(): TestFlight / the App
    /// Store update this app, so the page never offers the APK here.
    private static let bridgeScript = """
    window.RideWaveApp = {
      playback: function (json) { window.webkit.messageHandlers.rideWave.postMessage(String(json)); },
      versionCode: function () { return \(Config.build); }
    };
    """

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // cookies + localStorage survive restarts
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // The page detects the shell (and its version) from this suffix.
        config.applicationNameForUserAgent = "Mobile/15E148 RideWaveIOS/\(Config.version)"
        if Config.nativeNowPlaying {
            config.userContentController.add(WeakScriptHandler(self), name: "rideWave")
            config.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = Config.background
        webView.scrollView.backgroundColor = Config.background
        // The page lays itself out under the notch (viewport-fit=cover) and scrolls inside its own
        // panes, so no automatic insets and no rubber-banding of the whole app.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true } // Safari → Develop menu on a Mac
        #endif

        let root = UIView()
        root.backgroundColor = Config.background
        for v in [webView!, progress, offline] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        progress.progressTintColor = UIColor(red: 0x8E / 255.0, green: 0xF0 / 255.0, blue: 0xDA / 255.0, alpha: 1)
        progress.trackTintColor = .clear
        progress.isHidden = true

        let title = UILabel()
        title.text = "Kacheri is unreachable"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .white
        let body = UILabel()
        body.text = "Check your internet connection, or the radio may be offline."
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textColor = UIColor(red: 0xC3 / 255.0, green: 0xC8 / 255.0, blue: 0xE6 / 255.0, alpha: 1)
        body.numberOfLines = 0
        body.textAlignment = .center
        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(reload), for: .touchUpInside)
        offline.axis = .vertical
        offline.alignment = .center
        offline.spacing = 12
        [title, body, retry].forEach(offline.addArrangedSubview)
        offline.backgroundColor = Config.background
        offline.isHidden = true

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            offline.topAnchor.constraint(equalTo: root.topAnchor),
            offline.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            offline.leadingAnchor.constraint(equalTo: root.layoutMarginsGuide.leadingAnchor),
            offline.trailingAnchor.constraint(equalTo: root.layoutMarginsGuide.trailingAnchor),
        ])
        offline.isLayoutMarginsRelativeArrangement = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        nowPlaying.cookies = webView.configuration.websiteDataStore.httpCookieStore
        nowPlaying.onAction = { [weak self] action in self?.dispatch(action) }
        progressWatch = webView.observe(\.estimatedProgress) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showProgress() } // KVO fires on the main thread
        }
        webView.load(URLRequest(url: Config.radioURL))
    }

    /// A lock-screen / headset button, forwarded to the page.
    private func dispatch(_ action: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: action, options: .fragmentsAllowed),
              let arg = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__rwNative && window.__rwNative(\(arg))", completionHandler: nil)
    }

    private func showProgress() {
        let p = webView.estimatedProgress
        progress.setProgress(Float(p), animated: p > 0)
        progress.isHidden = p >= 1
    }

    @objc private func reload() {
        offline.isHidden = true
        if webView.url == nil { webView.load(URLRequest(url: Config.radioURL)) } else { webView.reload() }
    }

    private func loadFailed(_ error: Error) {
        let e = error as NSError
        // Cancelled, or a navigation we took over ourselves (sign-in, links opened outside).
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // frame load interrupted by policy
        offline.isHidden = false
        progress.isHidden = true
    }

    private func startSignIn() {
        signIn.start(anchor: view.window) { [weak self] exchange in
            guard let exchange else { return } // closed the sheet: stay on the login page
            self?.webView.load(exchange)
        }
    }

    static func isInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return host == Config.inAppDomain || host.hasSuffix("." + Config.inAppDomain)
    }

    private func openOutside(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        switch url.scheme?.lowercased() {
        case "about", "blob", "data":
            return .allow
        case "http", "https":
            break
        default:
            openOutside(url) // tel:, mailto:, maps …
            return .cancel
        }
        // Embedded frames load in place; only where the whole app goes is our business.
        if action.targetFrame?.isMainFrame == false { return .allow }
        if Self.isInApp(url) { return .allow } // the radio and sign-in stay in the app
        if SignInHandoff.isGoogleSignIn(url) {
            startSignIn()
            return .cancel
        }
        openOutside(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        offline.isHidden = true
        showProgress()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// iOS kills the page's process under memory pressure (often in the background): bring it back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

extension WebViewController: WKUIDelegate {
    /// target=_blank / window.open: ours in this view, anything else outside.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.isInApp(url) { webView.load(action.request) } else { openOutside(url) }
        }
        return nil
    }
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https",
              let url = URL(string: "https://\(origin.host)"), Self.isInApp(url),
              let json = message.body as? String else { return }
        nowPlaying.update(json: json)
    }
}

/// WKUserContentController holds its handlers strongly; this keeps it from holding the controller.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
