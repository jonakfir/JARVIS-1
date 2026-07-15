# JARVIS Meta Bridge (iOS)

A SwiftUI iPhone companion app that uses **Ray-Ban Meta glasses** with the JARVIS
backend through Meta's official **Wearables Device Access Toolkit (DAT)** iOS SDK.

**Identify Person** is a consent-gated one-shot flow: one tap captures one JPEG,
sends one targeted request, and shows transient visual results on Meta Ray-Ban
Display glasses. It never starts the periodic uploader or a live preview.

```
Ray-Ban Meta glasses camera
  → Meta Wearables Device Access Toolkit iOS SDK (MWDATCore / MWDATCamera)
  → this Swift/SwiftUI app  (JarvisMetaBridge)
  → JARVIS  POST /api/capture/frame
```

The other widgets may use their existing stream. Identify Person does not.

> ### Privacy / safety
> After obtaining the subject's clear, in-the-moment consent, the user can tap
> **Identify Person** to capture and send exactly one JPEG with **`target: true`**.
> That explicit, consent-gated action is the only identification path; it is never
> sent continuously, automatically, or on a timer. See
> [`JarvisFrameUploader.swift`](JarvisMetaBridge/JarvisFrameUploader.swift).

---

## What's in here

```
ios/JarvisMetaBridge/
├── JarvisMetaBridge.xcodeproj/         # Xcode project (SPM dependency preconfigured)
├── Config/
│   └── JarvisMetaBridge.xcconfig       # ← set signing team + Meta credentials here
├── JarvisMetaBridge/
│   ├── JarvisMetaBridgeApp.swift       # @main, Wearables.configure()
│   ├── AppConfig.swift                 # ← the ONE place the backend URL lives
│   ├── WearablesViewModel.swift        # Meta AI registration + device discovery
│   ├── StreamSessionViewModel.swift    # shared camera stream lifecycle
│   ├── ContentView.swift               # the widget hub (home grid)
│   ├── IdentifyPersonWidgetView.swift  # widget #1 UI
│   ├── JarvisFrameUploader.swift       # widget #1: frame → /api/capture/frame
│   ├── SceneDescribeWidgetView.swift   # widget #2 UI
│   ├── SceneDescribeService.swift      # widget #2: frame → /api/vision/describe
│   ├── SettingsView.swift              # edit backend URL at runtime
│   ├── Info.plist                      # Bluetooth / local-net / DAT config
│   └── JarvisMetaBridge.entitlements
└── README.md
```

## Widgets

The home screen is a hub of widgets built on `glasses frame → JARVIS AI → result`:

| # | Widget | What it does | Backend endpoint | Needs |
|---|--------|--------------|------------------|-------|
| 1 | **Identify Person** | Captures one consent-gated photo and presents a visual result | `POST /api/capture/frame` | PimEyes session for live identity |
| 2 | **Scene Describe** | One frame → Gemini caption ("what am I looking at?"), read aloud | `POST /api/vision/describe` | `GEMINI_API_KEY` |
| 3 | **Read It** | One frame → OCR visible text verbatim → read aloud (TTS) | `POST /api/vision/describe` | `GEMINI_API_KEY` |
| 4 | **Note Buddy** | High-res photo of a document → structured study note (title, summary, key points), saved to a local deck | `POST /api/vision/note` | `GEMINI_API_KEY` |
| 5 | **Voice Guide** | Hold-to-talk (on-device speech) → asks Claude about what you see → spoken answer. "Model freedom" (Claude/Gemini toggle) | `POST /api/vision/ask` | `ANTHROPIC_API_KEY` (or `GEMINI_API_KEY`) |

Widgets 2–3 share one endpoint and differ only by `prompt` — that's the template
for adding more. 2–5 read results aloud via `SpeechService` (AVSpeechSynthesizer).
Voice Guide uses Apple's on-device Speech framework for STT (`VoiceInputService`),
with the glasses acting as a Bluetooth mic; the model key stays server-side.

> **Build status:** the full app (18 Swift files) type-checks cleanly against the
> real Meta DAT SDK 0.4.0 + iOS SDK (0 errors). It was verified via `swiftc`
> because this build host couldn't mount an iOS Simulator runtime — so it has
> **not been run on a device here.** First run is on your Mac (below).

### Roadmap (researched, ranked by fit to the single-frame model)

Easy wins that are essentially a prompt swap on `/api/vision/describe`:

1. **Translate** — OCR a foreign sign/menu → translate to your language.
2. **ID Assist** (accessibility) — name a currency note / color / product label.
3. **Nutrition Snap** — frame a dish → rough calorie/macro estimate.
4. **Scan-to-Action** — QR / business card / receipt → structured data → file it (needs a parse + Convex write).
5. **Visual Memory** — snap + auto-caption a moment ("parked in row D4") to recall later (needs storage via the backend's SuperMemory/Convex).

Harder (need continuous video, audio, an enrolled face DB, or an AR display —
not one-shot frames): live captions/translation subtitles, turn-by-turn navigation,
named face-recognition, real-time hazard callouts.

The DAT SDK is added as a Swift Package (no manual download):
`https://github.com/facebook/meta-wearables-dat-ios` at exact version **0.4.0**,
products **MWDATCore** + **MWDATCamera**. Xcode resolves it automatically on first open.

---

## Requirements

- macOS with **Xcode 16+** (project targets iOS 17+).
- A **physical iPhone** (the DAT SDK needs real Bluetooth/External Accessory hardware — the Simulator will not connect to glasses).
- **Ray-Ban Meta glasses** updated to the latest firmware, paired in the **Meta AI** app.
- The **Meta AI** app installed on the same iPhone and signed in.
- A **Meta for Developers** app (App ID + Client token) — see below.
- An **Apple Developer** account (free personal team works for device installs).

---

## Step-by-step setup

### 1. Clone / install dependencies

```bash
git clone <repo-url>
cd JARVIS
```

The iOS dependencies (the Meta DAT SDK) are Swift Packages and are fetched by
Xcode automatically — there is nothing to `pip`/`npm`/`pod` install for the app itself.

### 2. Enable Meta Developer Mode

1. Go to **developers.facebook.com** → **My Apps** → **Create App**.
2. Note the numeric **App ID** and the **Client token**
   (App → *Settings → Advanced → Client token*).
3. Add the **Wearables Device Access Toolkit** product to the app and follow Meta's
   flow to enable **Developer Mode** for your glasses (this is done in the Meta AI
   app: *Settings → Developer* — toggle developer/experimental access on for the device).
4. Add your app's **App-link URL scheme** to the Meta app config: `jarvismetabridge://`
   (this must match `CFBundleURLTypes` / `MWDAT.AppLinkURLScheme` in `Info.plist`).

### 3. Open the project in Xcode

```bash
open ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj
```

On first open, Xcode resolves the `meta-wearables-dat-ios` package
(*File → Packages → Resolve Package Versions* if it doesn't start automatically).

### 4. Configure Meta DAT credentials

Open `Config/JarvisMetaBridge.xcconfig` and fill in:

```
CLIENT_TOKEN = <your Meta client token>
META_APP_ID  = <your numeric Meta App ID>
```

These flow into `Info.plist` (`MWDAT.ClientToken` / `MWDAT.MetaAppID`) at build time.

### 5. Set the Apple development team and bundle identifier

Either edit `Config/JarvisMetaBridge.xcconfig`:

```
DEVELOPMENT_TEAM = <your 10-char Team ID>
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.JarvisMetaBridge
```

…or in Xcode select the **JarvisMetaBridge** target → **Signing & Capabilities** →
check *Automatically manage signing*, pick your **Team**, and set a unique **Bundle
Identifier**. (The `TeamID` in `Info.plist` reads from `$(DEVELOPMENT_TEAM)`, so
setting it in the xcconfig keeps everything in sync.)

### 6. Find your Mac's local IP address

On the same Wi-Fi as the phone, run:

```bash
ipconfig getifaddr en0   # Wi-Fi; try en1 if blank
```

### 7. Set the JARVIS backend URL

Set [`AppConfig.swift`](JarvisMetaBridge/AppConfig.swift), or use the in-app
**gear → Settings**, to `http://<mac-ip>:8000` using the address from step 6.
Do not use `localhost`; on the iPhone that refers to the phone itself.

### 8. Start the JARVIS backend (bound to all interfaces)

Bind uvicorn to all interfaces so the phone can reach it (localhost-only will not
work from a device):

```bash
cd backend
uv sync
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Sanity check from your Mac (and the phone's Safari):
`http://<mac-ip>:8000/api/health` should return `{"status":"ok", ...}`.

> If the phone can't load that URL: check both devices are on the same network,
> and that the macOS firewall (*System Settings → Network → Firewall*) isn't
> blocking incoming connections to Python/uvicorn.

### 9. Configure the Google-authenticated PimEyes session

Identify Person uses a local export of the active PimEyes session. It never stores
or automates the Google password.

1. Open an incognito/private browser window and sign in to
   [PimEyes](https://pimeyes.com) with **Continue with Google** for
   `jonakfir@gmail.com`.
2. Confirm that a PimEyes search succeeds manually in that browser session.
3. Use a trusted cookie-export extension to export only `pimeyes.com` cookies as
   JSON. Cookie-Editor list JSON and name/value dictionary JSON are supported.
4. Save the export at `backend/identification/pimeyes_cookies.json`, relative to
   the repository root.
5. Never commit, share, or paste this file into logs. It grants access to the
   authenticated session and is intentionally ignored by Git.
6. Restart the backend after creating or replacing the file because cookies are
   cached in memory.
7. If the app reports expired or unauthorized cookies, export again from a fresh
   authenticated session, replace the file, and restart the backend.

`PIMEYES_EMAIL` and `PIMEYES_PASSWORD` do not reproduce Continue with Google for
this account. Leave them blank if present in a local environment and use the
cookie file instead.

### 10. Connect your physical iPhone

Plug the iPhone in (or use wireless debugging), select it as the **run destination**
in Xcode's toolbar, select the **JarvisMetaBridge** target, and confirm its Team and
unique bundle identifier under **Signing & Capabilities**. Then press **⌘R** to
build and run. Approve the developer certificate on the device the first time
(*Settings → General → VPN & Device Management*).

### 11. Register the app with Meta AI

In the running app, tap **Connect glasses (Meta AI)**. This calls the DAT SDK's
`startRegistration()`, which hands off to the Meta AI app and returns via the
callback configured by `MWDAT.AppLinkURLScheme` / `CFBundleURLTypes`. Use the Meta
App ID, client token, development team, and bundle identifier from
`Config/JarvisMetaBridge.xcconfig`. The callback scheme is configured in
`Info.plist`; register the matching value in the Meta app. With the current project
configuration that callback is `jarvismetabridge://`.
The **Meta AI** row turns green ("Registered").

### 12. Connect the glasses

With the glasses powered on, worn/open, and paired in Meta AI, the **Glasses** row
turns green when the SDK auto-selects an active device.

### 13. Grant camera permission

Tap **Identify Person** and confirm consent. The first time, DAT requests camera
access through Meta AI. Approve it, return to JARVIS, and tap again.

### 14. Capture once

After permission is granted, each confirmed tap starts a short-lived camera
capability, captures one JPEG, and stops it. No live preview or periodic upload runs.

### 15. Identify a consenting person

Use this manual sequence on the physical iPhone:

1. Tap **Connect glasses (Meta AI)** and wait for registration and an active device.
2. Obtain the person-in-view's clear, in-the-moment consent.
3. Tap **Identify Person** and confirm the consent dialog.
4. Grant camera permission through Meta AI if prompted, then retry once.
5. Keep the app open while it polls. The status progresses from requesting to
   identifying, then shows the resolved name or an actionable failure. If no
   terminal response arrives within 90 seconds, the button becomes available to retry.

Each confirmed attempt sends exactly one `target: true` JPEG. Do not use
identification continuously or without consent.

### 16. Confirm frames reach JARVIS

- In the app: **Upload status** shows `OK · N detection(s) · capture …`, **Frames
  accepted** increments, and **Latest detections** reflects JARVIS's YOLO output.
- On the backend: watch the log
  ```bash
  tail -f /tmp/jarvis_backend.log
  ```
  You'll see `POST /api/capture/frame` activity and detection counts.

Tap **Stop Stream** to end.

---

## Common Xcode & networking errors

| Symptom | Fix |
|---|---|
| *"Missing package product 'MWDATCore'"* | *File → Packages → Reset Package Caches*, then *Resolve Package Versions*. Ensure you're online. |
| Package fails to resolve | Confirm the URL `github.com/facebook/meta-wearables-dat-ios` is reachable and version `0.4.0` exists. |
| *"Signing requires a development team"* | Set `DEVELOPMENT_TEAM` in the xcconfig or pick a Team in Signing & Capabilities. |
| App installs but won't launch on device | Trust your dev certificate: *Settings → General → VPN & Device Management*. |
| Glasses row never turns green | Ensure glasses are paired in Meta AI, powered on, worn/open, on latest firmware, and Developer Mode is enabled. |
| Registration never completes | Verify `jarvismetabridge://` is registered both in `Info.plist` and in your Meta app config, and that `CLIENT_TOKEN`/`META_APP_ID` are correct. |
| Upload status stuck on *"Network error"* | Backend must run with `--host 0.0.0.0`; use your Mac's **LAN IP** (not `localhost`); same Wi-Fi; firewall allows uvicorn. |
| *"App Transport Security blocked … cleartext"* | Already handled: `Info.plist` sets `NSAllowsLocalNetworking`. Use `http://<LAN-IP>:8000`, not a public hostname. |
| HTTP 422 from JARVIS | The request body shape drifted from `backend/schemas.py::FrameSubmission`. Don't edit the uploader's JSON keys. |
| Preview shows frames but detections stay 0 | Normal if no people are in view — JARVIS runs YOLO person detection per frame. |

---

## Distributing via TestFlight

The app is a **Glasses Widgets** hub — a home grid of widgets, with **Identify
Person** as widget #1 (add more by dropping new cards into `ContentView.swift`).
To get it onto your phone (and testers') via TestFlight:

1. You need a **paid Apple Developer Program** membership ($99/yr) and an app
   record in **App Store Connect** matching your bundle identifier.
2. In Xcode: set the run destination to **Any iOS Device (arm64)** →
   **Product → Archive**.
3. In the Organizer window: **Distribute App → TestFlight (Internal Testing)** →
   upload. (Uses your `DEVELOPMENT_TEAM` signing.)
4. In App Store Connect → TestFlight, add yourself/testers. The build needs an
   **encryption-compliance** answer (this app uses only standard HTTPS/JSON, so
   the "exempt" path applies) before it can be installed.
5. Note: TestFlight installs the app, but it still talks to **your Mac's local
   JARVIS backend** over your LAN — testers must be on the same network as the
   machine running uvicorn, or you must host JARVIS somewhere reachable.

> For just running it on your own device, you don't need TestFlight at all —
> plug in and ⌘R (steps above). TestFlight is only for over-the-air distribution.

## Still needs YOUR credentials / accounts

The code is complete, but these values are personal and cannot be committed:

1. **Meta App ID** and **Client token** → `Config/JarvisMetaBridge.xcconfig`.
2. **Apple Developer Team ID** + a unique **bundle identifier** → xcconfig or Signing UI.
3. **Meta AI Developer Mode** enabled for your glasses (in the Meta AI app).
4. The **App-link callback scheme** `jarvismetabridge://` registered in your Meta app config.
5. Your **Mac's LAN IP** in `AppConfig.swift` (or via the in-app Settings screen).
