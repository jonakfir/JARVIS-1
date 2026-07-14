# Meta Glasses to PimEyes Identification Design

Date: 2026-07-14

## Goal

Finish the existing Identify Person path from Ray-Ban Meta glasses to JARVIS and PimEyes. Preserve the other iOS widgets without modifying them.

The supported flow is:

1. The user registers the iOS app through Meta AI and connects supported glasses.
2. The app obtains camera permission and starts the Meta DAT video stream.
3. Normal preview frames are uploaded to `POST /api/capture/frame` at no more than one frame per second with `target: false`.
4. After obtaining the subject's consent, the user taps **Identify person** once.
5. The current frame is uploaded to the same endpoint with `target: true`.
6. JARVIS detects people, selects the most prominent person, and starts one asynchronous face-search job.
7. Later detection-only responses carry the current identification state until the UI shows the resolved name or failure.

Continuous or automatic `target: true` uploads are out of scope.

## Existing API Contract

`backend/schemas.py` is the source of truth.

### Request

`POST /api/capture/frame` accepts JSON matching `FrameSubmission`:

- `frame`: base64-encoded JPEG without a required data-URL prefix
- `timestamp`: Unix epoch milliseconds as an integer
- `source`: `meta_glasses_ios`
- `target`: `false` for streaming and `true` for the explicit one-shot identification action

### Response

The response matches `FrameProcessedResponse`:

- `capture_id`: string
- `detections`: array of bounding box, confidence, and optional track ID
- `new_persons`: integer
- `identifications`: array containing track ID, status, optional name, optional person ID, and an optional actionable error
- `timestamp`: echoed integer
- `source`: echoed string

Identification is asynchronous. The response to the triggering request can report `identifying`; a later frame response reports `identified` or `failed`.

## iOS Design

The existing `ios/JarvisMetaBridge` Xcode project remains the app location. It uses SwiftUI and Meta's official Swift package, pinned to `meta-wearables-dat-ios` 0.4.0 with products `MWDATCore` and `MWDATCamera`.

The implementation continues to follow the bundled official `samples/CameraAccess` APIs:

- `Wearables.configure()` and `Wearables.shared`
- `startRegistration()`, `handleUrl(_:)`, and registration/device streams
- `AutoDeviceSelector`
- `Permission.camera`
- `StreamSession`, `StreamSessionConfig`, and raw `VideoFrame.makeUIImage()` conversion
- stream state, frame, and error publishers

`JarvisFrameUploader` owns the JARVIS wire contract. The regular `submit(image:)` path JPEG-encodes at 0.70 quality, throttles to one request per second, prevents overlap, and always sends `target: false`. The separate `identify(image:)` method performs one user-initiated request with `target: true`. After JARVIS accepts that request, the Identify button remains disabled while later detection-only responses report `identifying`. It is re-enabled when a response reports `identified` or `failed`, or after a 90-second client timeout so the user can retry after a lost response.

The Identify Person screen shows registration, device, permission, and stream state; live preview; backend URL; upload status; detection count; identification state; resolved name; and visible errors. Other widget source files and behavior remain unchanged.

## Backend and PimEyes Design

`FrameHandler` remains the single coordinator for frame detection and identification. A `target: true` frame may start a search only when a person is detected and no search is already running. When multiple people are detected, the target is the detection with the largest bounding-box area, not the crop with the largest encoded byte count. The search lock must be released on success, no-match results, missing configuration, and exceptions.

PimEyes authentication uses an interactive Google login for `jonakfir@gmail.com`. No Google password, PimEyes password, session token, or cookie is committed or hardcoded. The supported local setup is:

1. Sign into PimEyes with Google in a browser.
2. Export the active PimEyes cookies as JSON.
3. Save them locally at `backend/identification/pimeyes_cookies.json`.
4. Rely on the existing `.gitignore` rule that excludes `pimeyes_cookies.json`.
5. Restart JARVIS after replacing expired cookies.

The direct cookie-authenticated PimEyes API remains the primary path. Existing reverse-image and Browser Use fallbacks are not redesigned. Documentation must not imply that `PIMEYES_EMAIL` and `PIMEYES_PASSWORD` can reproduce Google OAuth login.

## Error Handling

- Invalid backend URLs, JPEG failures, transport errors, non-2xx responses, and JSON-decoding failures appear in the iOS UI and logs.
- Throttled or overlapping stream frames are dropped silently because a newer frame will arrive.
- A second identification tap is ignored while the first request is in flight.
- After the trigger request returns, further identification taps remain disabled until a later frame response reports a terminal state or the 90-second retry timeout expires.
- A backend search already in progress does not spawn another PimEyes job.
- Missing or expired PimEyes cookies produce an actionable optional `error` value in the identification response and leave the search lock reusable.
- The iOS app distinguishes request acceptance from completed identification.

## Verification

Focused verification will cover:

- Swift compilation with workspace-local DerivedData and package checkout paths
- Meta imports, types, and methods against the pinned package and bundled official sample
- request and response models against the Python Pydantic schemas
- `target: false` on normal streaming and `target: true` only on the explicit identification action
- one-frame-per-second throttling and non-overlapping uploads
- backend tests for detection-only frames, identification triggering, concurrent-search suppression, completion polling, and lock release after failure
- largest-bounding-box target selection and optional identification-error serialization
- cookie file ignore behavior and documentation for Google-authenticated PimEyes accounts
- existing backend tests relevant to capture and face search

Live end-to-end verification still requires a physical iPhone, supported Meta glasses, a configured Meta developer app, Apple signing, and a valid authenticated PimEyes browser session.

## Scope Boundaries

This work does not redesign or remove Scene Describe, Note Buddy, Read It, Voice Guide, web widgets, dossier generation, enrichment, or unrelated backend APIs. It does not commit credentials or automate Google login. It does not make identification continuous or covert.
