# Beam iOS

iPhone shell around the Beam web app (formerly Kacheri) (repo `D:\apps\ridewave`) at `https://beam.nikolatesla.co.in`.
It is the iOS counterpart of `ridewave-android` and uses the same page bridge, plus what a web page can't do by itself:

- **Plays in the background like a real music app.** `UIBackgroundModes: audio` and an
  `AVAudioSession` in `.playback` keep the web view's `<audio>` going with the screen locked.
  The page's silent keep-alive loop (`public/js/keepalive.js`) keeps iOS from suspending it between songs.
- **Lock-screen / Control Center, headset and intercom buttons** through `MPNowPlayingInfoCenter` +
  `MPRemoteCommandCenter` (`NowPlaying.swift`). The page reports what's playing via
  `window.RideWaveApp.playback(json)`, which the shell injects and routes to a `WKScriptMessageHandler`.
  Button presses come back through `window.__rwNative(action)` (see `public/js/native.js`).
- **Google sign-in** goes through `ASWebAuthenticationSession` and Passport's `/app-auth` handoff
  (`SignInHandoff.swift`). This is the same PKCE flow as Android: Passport returns `ridewave://auth?code=…`, and the
  code + verifier are POSTed to `/app-auth/exchange` inside the web view.
- Links under `nikolatesla.co.in` stay in the app. Everything else opens in Safari or the matching app, and
  swiping back from the left edge goes back.
- **No self-update.** iOS doesn't allow it. New builds reach phones through TestFlight or the App Store.
  The page recognises the shell by `RideWaveIOS/<version>` in the user agent and doesn't offer the APK.

## Build

There's no Mac here, so builds run on GitHub's macOS runners (`.github/workflows/ios.yml`):

1. Push this folder to a GitHub repo. macOS minutes are free on public repos. Private repos use them
   at 10× the rate, which means about 200 macOS minutes a month on the free plan.
2. Every push compiles for the simulator (unsigned). That checks the code builds.
3. **Actions → iOS → Run workflow → testflight** archives, signs and uploads to TestFlight.

On a Mac the steps are: `brew install xcodegen && xcodegen generate && open Beam.xcodeproj`.
Then set the team under Signing and run on a phone.

## One-time Apple setup (for TestFlight)

1. Join the Apple Developer Program ($99/year).
2. App Store Connect → Apps → **+** → new iOS app, bundle ID `in.co.nikolatesla.ridewave`, name "Beam".
3. Users and Access → Integrations → App Store Connect API → generate a key with the **Admin** role.
   Admin lets the build create its distribution certificate and profile in the cloud.
4. Add the repo secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`
   (the .p8 file's contents).
5. After the first upload, go to TestFlight → add testers by email, or turn on a public link.
   Riders install the **TestFlight** app and then Beam from it. Each build expires after 90 days.

Bump `MARKETING_VERSION` in `project.yml` for each release. The build number is the CI run number.

## Things to check on a real iPhone

- **Lock screen:** WebKit may publish the page's Media Session to the lock screen as well. If the
  native controls and WebKit's fight (the lock screen flickers between the two, or buttons act twice),
  set `Config.nativeNowPlaying = false` and let WebKit own it.
- **A ride in the pocket:** check that music survives locking the screen, song changes and a lost signal.
- **Sign-in:** Google sign-in should return to the app already signed in.

## Icon

`node tools/make-icons.js --ios D:\apps\ridewave-ios` (in the ridewave repo) renders
`AppIcon.appiconset/icon-1024.png` from `design/icon.svg`. The file is opaque because App Store Connect rejects icons with alpha.
