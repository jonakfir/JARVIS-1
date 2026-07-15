# One-Shot Display Identification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `work-audit-refine:war` to implement this plan phase-by-phase in an isolated worktree. Use `superpowers:test-driven-development` within every task. Stop for user approval and an independent auditor pass at every phase boundary.

**Goal:** Capture one still image per confirmed tap, identify the consenting subject, and show a transient visual-only name card on Meta Ray-Ban Display that updates with a directly matched LinkedIn role when available.

**Architecture:** Upgrade the iOS companion app to the current Meta Wearables DAT session/camera/display APIs. A request-scoped backend contract admits one asynchronous identification and exposes polling without requiring continuous frame uploads. Focused iOS coordinators own temporary photo capture, glasses display timing, and the name-first/enrichment state machine.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Meta Wearables DAT 0.8.x (`MWDATCore`, `MWDATCamera`, `MWDATDisplay`, `MWDATMockDevice` for tests), Python 3.13, FastAPI, Pydantic, pytest, httpx.

## Global Constraints

- Preserve one `target: true` submission per confirmed identification attempt.
- Never start periodic backend uploads from Identify Person.
- DAT may create video frames internally only long enough to capture one JPEG; none of those video frames may be uploaded.
- Display output is visual only. Never call a speech or audio API as a fallback.
- Show **Identifying…** until a terminal identity result replaces it.
- Show **Not identified** for exactly three seconds on terminal failure.
- Show the name immediately; a directly matched LinkedIn result updates or re-presents the same card as `Name — Role at Company` for a fresh three seconds.
- Never infer a job from a name-only LinkedIn search. Require a LinkedIn URL present in the face-search evidence.
- Only one attempt may be active at once. Cancellation must stop camera/display capabilities, polling, and stale clear timers.
- Keep Meta client credentials in `JarvisMetaBridge.local.xcconfig`, which remains gitignored.
- Retain the explicit in-the-moment consent confirmation.
- All implementation occurs through WAR phase gates with user approval before advancing.

---

## File Structure

### Backend

- `backend/capture/frame_handler.py`: request-scoped identification lifecycle and terminal state.
- `backend/identification/linkedin_enricher.py`: strict best-effort extraction from a directly matched LinkedIn URL.
- `backend/schemas.py`: one-shot request/status response contracts.
- `backend/main.py`: submit and status endpoints.
- `backend/tests/test_capture.py`: admission, null tracker, polling, and one-request regression tests.
- `backend/tests/test_linkedin_enricher.py`: direct-URL validation and metadata parsing tests.

### iOS

- `ios/JarvisMetaBridge/JarvisMetaBridge/OneShotCaptureCoordinator.swift`: temporary stream and single JPEG capture.
- `ios/JarvisMetaBridge/JarvisMetaBridge/GlassesDisplayPresenter.swift`: attach/send/update/clear behavior for display-capable glasses.
- `ios/JarvisMetaBridge/JarvisMetaBridge/IdentificationAPIClient.swift`: one submit plus status polling.
- `ios/JarvisMetaBridge/JarvisMetaBridge/OneShotIdentificationViewModel.swift`: user-facing orchestration state machine.
- `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonDisplayCard.swift`: MWDAT display view factory.
- `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift`: one-shot controls and phone diagnostics.
- `ios/JarvisMetaBridge/JarvisMetaBridge/Info.plist`: DAM and current DAT requirements.
- `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`: DAT 0.8 products, new source files, and test target wiring.
- `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: resolved 0.8.x SDK.
- `ios/JarvisMetaBridge/JarvisMetaBridgeTests/*.swift`: coordinator, display timer, API, and orchestration tests.

### Hosted association source

- `deploy/universal-link/apple-app-site-association`: committed source for the already deployed Vercel association response.
- `deploy/universal-link/vercel.json`: content type, callback rewrite, and association rewrite.

---

## Phase 1 — Stabilize and Preserve the Working Baseline

### Task 1: Commit the proven camera-registration and null-tracker fixes

**Files:**
- Modify: `.gitignore`
- Modify: `backend/capture/frame_handler.py`
- Modify: `backend/tests/test_capture.py`
- Modify: `ios/JarvisMetaBridge/Config/JarvisMetaBridge.xcconfig`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/Info.plist`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridge.entitlements`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridgeApp.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift`
- Create: `deploy/universal-link/apple-app-site-association`
- Create: `deploy/universal-link/index.html`
- Create: `deploy/universal-link/vercel.json`

**Interfaces:**
- Produces: a buildable signed iOS baseline, valid universal-link callback, and integer `track_id` sentinel `-1`.

- [ ] **Step 1: Re-run the null-tracker regression test**

Run:

```bash
cd backend
uv run pytest -o addopts='' tests/test_capture.py::test_target_without_yolo_track_id_returns_valid_identification -q
```

Expected: `1 passed`.

- [ ] **Step 2: Verify local credentials are ignored and public configuration is valid**

Run:

```bash
git check-ignore -q ios/JarvisMetaBridge/Config/JarvisMetaBridge.local.xcconfig
plutil -lint ios/JarvisMetaBridge/JarvisMetaBridge/Info.plist
plutil -lint ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridge.entitlements
curl -fsS https://jarvis-meta-bridge-links.vercel.app/.well-known/apple-app-site-association | jq -e '.applinks.details[0].appIDs[0] == "3K8N98ZS5T.com.jonakfir.JarvisMetaBridge"'
```

Expected: all commands exit 0 and no client token appears in `git diff`.

- [ ] **Step 3: Move the deployed static source out of scratch storage**

Create the three `deploy/universal-link` files with the already deployed content. The AASA body must remain:

```json
{
  "applinks": {
    "details": [{
      "appIDs": ["3K8N98ZS5T.com.jonakfir.JarvisMetaBridge"],
      "components": [{"/": "/meta-wearables/*"}]
    }]
  }
}
```

- [ ] **Step 4: Run the full current verification suite**

Run:

```bash
cd backend && uv run pytest -q
xcodebuild -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

Expected: `304 passed, 5 skipped` or more, coverage at least 46%, and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit the baseline**

```bash
git add .gitignore backend/capture/frame_handler.py backend/tests/test_capture.py \
  ios/JarvisMetaBridge/Config/JarvisMetaBridge.xcconfig \
  ios/JarvisMetaBridge/JarvisMetaBridge/Info.plist \
  ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridge.entitlements \
  ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridgeApp.swift \
  ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift \
  deploy/universal-link
git commit -m "fix: stabilize Meta glasses registration and capture"
```

### Phase 1 gate

Independent auditor confirms the committed baseline contains no secrets, preserves `target: true`, and passes backend plus signed-device builds. Stop for user approval.

---

## Phase 2 — Request-Scoped Backend Identification

### Task 2: Add one-shot admission and polling contracts

**Files:**
- Modify: `backend/schemas.py`
- Modify: `backend/capture/frame_handler.py`
- Modify: `backend/main.py`
- Modify: `backend/tests/test_capture.py`

**Interfaces:**
- Produces: `POST /api/capture/frame` returning `request_id`; `GET /api/capture/identification/{request_id}` returning `IdentificationStatusResponse`.
- Produces: `FrameHandler.get_identification(request_id: str) -> Identification | None`.

- [ ] **Step 1: Write failing API and handler tests**

Add tests that assert:

```python
result = await handler.process_frame(FRAME, 1, "meta_glasses_ios", target=True)
request_id = result["identifications"][0]["request_id"]
assert isinstance(request_id, str) and request_id
assert handler.get_identification(request_id).status == "identifying"

response = client.get(f"/api/capture/identification/{request_id}")
assert response.status_code == 200
assert response.json()["request_id"] == request_id
assert client.get("/api/capture/identification/missing").status_code == 404
```

Also assert a second `target: true` request while one is active returns an explicit non-admission result and never spawns a second task.

- [ ] **Step 2: Run the new tests and confirm RED**

```bash
cd backend
uv run pytest -o addopts='' tests/test_capture.py -k 'request_id or identification_status or second_target' -q
```

Expected: failures for missing request-scoped API and model fields.

- [ ] **Step 3: Implement request-scoped models**

Extend the internal `Identification` with:

```python
request_id: str
track_id: int
status: str
name: str | None
linkedin_url: str | None
job_title: str | None
company: str | None
error: str | None
```

Add Pydantic models whose JSON keys match the iOS client exactly:

```python
class IdentificationStatusResponse(BaseModel):
    request_id: str
    track_id: int
    status: Literal["identifying", "identified", "failed"]
    name: str | None = None
    linkedin_url: str | None = None
    job_title: str | None = None
    company: str | None = None
    error: str | None = None
```

Store attempts in `self._identifications_by_request_id`. Return 404 for unknown IDs. Do not require new camera frames to observe completion.

- [ ] **Step 4: Run focused and full backend tests**

```bash
cd backend
uv run pytest -o addopts='' tests/test_capture.py -q
uv run pytest -q
```

Expected: focused tests pass; full suite passes coverage gate.

- [ ] **Step 5: Commit**

```bash
git add backend/schemas.py backend/capture/frame_handler.py backend/main.py backend/tests/test_capture.py
git commit -m "feat: add request-scoped identification polling"
```

### Task 3: Add strict direct-LinkedIn enrichment

**Files:**
- Create: `backend/identification/linkedin_enricher.py`
- Create: `backend/tests/test_linkedin_enricher.py`
- Modify: `backend/capture/frame_handler.py`
- Modify: `backend/identification/search_manager.py`

**Interfaces:**
- Produces: `LinkedInRole(job_title: str, company: str | None)`.
- Produces: `LinkedInEnricher.enrich(profile_url: str) -> LinkedInRole | None`.
- Consumes: LinkedIn URL returned by `FaceSearchManager.profile_urls_from_results`.

- [ ] **Step 1: Write failing URL-policy and metadata tests**

Tests must cover:

```python
assert enricher.is_allowed_profile_url("https://www.linkedin.com/in/jane-doe")
assert not enricher.is_allowed_profile_url("https://www.linkedin.com/search/results/people/?keywords=Jane")
assert not enricher.is_allowed_profile_url("https://example.com/in/jane-doe")

html = '<meta property="og:title" content="Jane Doe - Engineer at Acme | LinkedIn">'
assert parse_role(html) == LinkedInRole(job_title="Engineer", company="Acme")
```

Include ambiguous/missing metadata returning `None`.

- [ ] **Step 2: Run tests and confirm RED**

```bash
cd backend
uv run pytest -o addopts='' tests/test_linkedin_enricher.py -q
```

- [ ] **Step 3: Implement strict enrichment**

Use `urllib.parse` to require HTTPS, host `linkedin.com` or `www.linkedin.com`, and path prefix `/in/`. Fetch only that exact evidence URL with `httpx.AsyncClient(follow_redirects=True, timeout=10)`. Parse OpenGraph/title metadata; do not authenticate, search by name, or bypass access controls.

After name resolution, select the first direct LinkedIn profile URL from the same face-search result, set `ident.linkedin_url`, mark the name as identified immediately, then run enrichment asynchronously. Update `job_title` and `company` only on a confident parse.

- [ ] **Step 4: Verify name is observable before enrichment completes**

Add an async test using an `asyncio.Event`-blocked fake enricher:

```python
assert handler.get_identification(request_id).name == "Jane Doe"
assert handler.get_identification(request_id).job_title is None
event.set()
await wait_for_role(handler, request_id)
assert handler.get_identification(request_id).job_title == "Engineer"
```

- [ ] **Step 5: Run backend suite and commit**

```bash
cd backend && uv run pytest -q
git add backend/identification/linkedin_enricher.py backend/identification/search_manager.py \
  backend/capture/frame_handler.py backend/tests/test_linkedin_enricher.py backend/tests/test_capture.py
git commit -m "feat: enrich direct LinkedIn identification matches"
```

### Phase 2 gate

Independent auditor verifies exactly one admission, request isolation, no name-only LinkedIn lookup, failure transparency for missing PimEyes, and passing full backend tests. Stop for user approval.

---

## Phase 3 — DAT 0.8 Migration and Test Harness

### Task 4: Upgrade Meta Wearables DAT and add the iOS test target

**Files:**
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/Info.plist`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/StreamSessionViewModel.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/SmokeTests.swift`

**Interfaces:**
- Produces: buildable imports for `MWDATCore`, `MWDATCamera`, `MWDATDisplay`, and test-only `MWDATMockDevice`.

- [ ] **Step 1: Add a test target with a deliberately failing smoke test**

```swift
import XCTest
@testable import JarvisMetaBridge

final class SmokeTests: XCTestCase {
  func testHarnessRuns() { XCTFail("RED: test harness connected") }
}
```

Run:

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS Simulator'
```

Expected: failure containing `RED: test harness connected`.

- [ ] **Step 2: Pin DAT to 0.8.x and add package products**

Set the Swift package requirement to `upToNextMinorVersion` from `0.8.0`. Add `MWDATDisplay` to the app and `MWDATMockDevice` to tests. Add under `MWDAT`:

```xml
<key>DAMEnabled</key>
<true/>
```

Retain the Wearables Developer Center application ID, client token substitution, Team ID, callback configuration, `fb-viewapp`, accessory protocol, local-network, Bluetooth, and background-mode keys.

- [ ] **Step 3: Migrate existing camera types to 0.8**

Replace 0.4 APIs with the current session model:

```swift
let session = try wearables.createSession(deviceSelector: selector)
try session.start()
let stream = try session.addStream(config: configuration)
stream?.start()
```

Use `Stream`, `StreamConfiguration`, `StreamState`, and `StreamError`; lifecycle start/stop calls are synchronous in 0.8. Preserve behavior of non-identification widgets.

- [ ] **Step 4: Make the smoke test pass and compile all targets**

Replace the deliberate failure with `XCTAssertTrue(true)`, then run:

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS Simulator'
xcodebuild -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

Expected: `TEST SUCCEEDED` and signed-device `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisMetaBridge
git commit -m "refactor: migrate Meta Wearables SDK to DAT 0.8"
```

### Phase 3 gate

Independent auditor compares migration code against Meta's official 0.8 CameraAccess and DisplayAccess samples, checks credentials remain untracked, and confirms simulator tests plus signed device build. Stop for user approval.

---

## Phase 4 — iOS One-Shot Capture, Display, and API Units

### Task 5: Implement the request client

**Files:**
- Create: `ios/JarvisMetaBridge/JarvisMetaBridge/IdentificationAPIClient.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/IdentificationAPIClientTests.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `submit(jpegData: Data) async throws -> IdentificationTicket`.
- Produces: `status(requestID: String) async throws -> IdentificationResult`.
- Guarantees: submit payload always encodes `target: true` and `source: "meta_glasses_ios"`.

- [ ] **Step 1: Write failing URLProtocol-backed tests**

Assert one POST body contains:

```json
{"target":true,"source":"meta_glasses_ios"}
```

Assert status uses `GET /api/capture/identification/{requestID}` and decodes identifying, identified/name, enriched job, failed, HTTP error, timeout, and malformed response cases.

- [ ] **Step 2: Confirm RED**

Run only `IdentificationAPIClientTests`; expect missing-type compile failures.

- [ ] **Step 3: Implement the smallest client**

Use injected `URLSession` and `AppConfig`. Define `Codable`, `Sendable`, `Equatable` value types. Do not reuse the periodic `JarvisFrameUploader.submit` path.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'id=00008150-001A386E0152401C' \
  -only-testing:JarvisMetaBridgeTests/IdentificationAPIClientTests
git add ios/JarvisMetaBridge
git commit -m "feat: add one-shot identification API client"
```

### Task 6: Implement temporary still capture

**Files:**
- Create: `ios/JarvisMetaBridge/JarvisMetaBridge/OneShotCaptureCoordinator.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/OneShotCaptureCoordinatorTests.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `captureJPEG() async throws -> Data`.
- Produces: `cancel()`.
- Guarantees: at most one `capturePhoto(format: .jpeg)` call and cleanup after success, failure, cancellation, or 15-second timeout.

- [ ] **Step 1: Write protocol-fake tests first**

Create narrow app-owned adapters around DAT so tests can assert this sequence:

```text
create display-capable session → start session → add stream → start stream
→ wait for .streaming → capturePhoto(.jpeg) once → receive PhotoData
→ stop stream → stop session
```

Assert no video-frame callback invokes an uploader and all failure paths stop resources.

- [ ] **Step 2: Confirm RED**

Run `OneShotCaptureCoordinatorTests`; expect missing coordinator/adapters.

- [ ] **Step 3: Implement against current DAT APIs**

Use `AutoDeviceSelector(wearables:filter: { $0.supportsDisplay() })`, `DeviceSession.addStream`, `Stream.photoDataPublisher`, and a checked continuation guarded against double resume. Ignore `videoFramePublisher` entirely.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'id=00008150-001A386E0152401C' \
  -only-testing:JarvisMetaBridgeTests/OneShotCaptureCoordinatorTests
git add ios/JarvisMetaBridge
git commit -m "feat: capture one still from Meta display glasses"
```

### Task 7: Implement visual-only display presentation

**Files:**
- Create: `ios/JarvisMetaBridge/JarvisMetaBridge/GlassesDisplayPresenter.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonDisplayCard.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/GlassesDisplayPresenterTests.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `showIdentifying() async`, `showName(_:) async`, `showEnriched(name:role:company:) async`, `showNotIdentified() async`, `clear() async`, and `cancel()`.
- Guarantees: result cards clear after three seconds; updated cards cancel stale clear tasks and start a fresh timer.

- [ ] **Step 1: Write failing fake-clock/display tests**

Test exact text and timing:

```swift
await presenter.showName("Jane Doe")
await clock.advance(by: .seconds(2))
await presenter.showEnriched(name: "Jane Doe", role: "Engineer", company: "Acme")
await clock.advance(by: .seconds(1))
XCTAssertFalse(display.didClear)
await clock.advance(by: .seconds(2))
XCTAssertTrue(display.didClear)
```

Also test a late enrichment card reappears after the name card cleared and that no audio interface exists or is invoked.

- [ ] **Step 2: Confirm RED**

Run `GlassesDisplayPresenterTests`; expect missing presenter.

- [ ] **Step 3: Implement display-capable session and card factory**

Use `AutoDeviceSelector(wearables:filter: { $0.supportsDisplay() })`, `DeviceSession.addDisplay()`, `Display.start()`, `Display.send(_:)`, and `Display.clearDisplay()`. Build high-contrast `FlexBox`/`MWDATDisplay.Text` cards suitable for the additive display. Keep display types out of SwiftUI-ambiguous namespaces.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'id=00008150-001A386E0152401C' \
  -only-testing:JarvisMetaBridgeTests/GlassesDisplayPresenterTests
git add ios/JarvisMetaBridge
git commit -m "feat: present transient identity cards on glasses"
```

### Phase 4 gate

Independent auditor verifies one photo call, no periodic upload, visual-only output, exact timer cancellation behavior, and passing focused plus complete iOS tests. Stop for user approval.

---

## Phase 5 — Orchestration and UI Replacement

### Task 8: Build the one-shot identification state machine

**Files:**
- Create: `ios/JarvisMetaBridge/JarvisMetaBridge/OneShotIdentificationViewModel.swift`
- Create: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/OneShotIdentificationViewModelTests.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `captureJPEG`, `submit`, `status`, and display-presenter methods from Tasks 5–7.
- Produces: `startIdentification()`, `cancel()`, `state`, `diagnosticMessage`, `isBusy`.

- [ ] **Step 1: Write orchestration tests first**

Cover:

```text
tap → Identifying card → one capture → one target:true submit
→ poll → name card immediately → continue poll
→ same card updated with direct LinkedIn role
```

Also cover failure to Not identified, absent job remaining name-only, late job reappearance, duplicate tap ignored, 90-second timeout, cancellation, and screen dismissal.

- [ ] **Step 2: Confirm RED**

Run only `OneShotIdentificationViewModelTests`; expect missing state machine.

- [ ] **Step 3: Implement with structured concurrency**

Use one owned `Task<Void, Never>?`. Poll at one-second intervals. Treat `identified` plus a name as the name milestone; continue polling until role arrives, terminal failure, or deadline. Do not re-capture or re-submit during polling.

- [ ] **Step 4: Run tests and commit**

```bash
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'id=00008150-001A386E0152401C' \
  -only-testing:JarvisMetaBridgeTests/OneShotIdentificationViewModelTests
git add ios/JarvisMetaBridge
git commit -m "feat: orchestrate one-shot glasses identification"
```

### Task 9: Replace Identify Person continuous controls

**Files:**
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/ContentView.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/JarvisMetaBridgeApp.swift`
- Modify: `ios/JarvisMetaBridge/README.md`
- Test: `ios/JarvisMetaBridge/JarvisMetaBridgeTests/IdentifyPersonFlowTests.swift`

**Interfaces:**
- Consumes: `OneShotIdentificationViewModel`.
- Removes from Identify Person: `Start Stream`, `Stop Stream`, continuously updating preview, and periodic uploader state.

- [ ] **Step 1: Write a failing UI/state assertion**

Test that the Identify Person model exposes one enabled action only while idle, confirmation triggers `startIdentification` once, and dismissal calls `cancel`.

- [ ] **Step 2: Confirm RED**

Run the focused flow test and confirm it fails against the continuous-stream UI.

- [ ] **Step 3: Implement the one-shot screen**

Keep connection status, backend endpoint, diagnostics, and consent dialog. Replace streaming controls with one primary **Identify Person** button and progress label derived from the state machine. Do not show or retain a live camera preview.

- [ ] **Step 4: Verify all automated checks**

```bash
cd backend && uv run pytest -q
xcodebuild test -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS Simulator'
xcodebuild -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
git diff --check
```

Expected: backend suite and coverage pass, iOS `TEST SUCCEEDED`, signed-device `BUILD SUCCEEDED`, clean diff check.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisMetaBridge
git commit -m "feat: replace streaming identification with one-shot flow"
```

### Phase 5 gate

Independent auditor traces the button-to-photo-to-one-POST-to-poll-to-display flow, confirms `target: true` remains, and verifies no continuous upload path is reachable from Identify Person. Stop for user approval.

---

## Phase 6 — Physical Meta Ray-Ban Display Verification

### Task 10: Install and verify on the real device

**Files:**
- Modify only if a verified defect is found; each defect requires a new failing regression test before code changes.

- [ ] **Step 1: Build and install the signed app**

```bash
xcodebuild -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device A89AC3C6-EEAE-5B72-8934-1F5A4F422AD5 \
  ~/Library/Developer/Xcode/DerivedData/JarvisMetaBridge-*/Build/Products/Debug-iphoneos/JarvisMetaBridge.app
```

- [ ] **Step 2: Start the verified backend**

```bash
cd backend
uv run uvicorn main:app --host 0.0.0.0 --port 8000
```

Confirm `/api/health` is 200 and port 8000 is owned by the current WAR worktree, not a deleted worktree.

- [ ] **Step 3: Verify camera and display prerequisites**

Confirm Meta AI registration, camera permission, display-capable device selection, and DAT glasses app compatibility. If the SDK reports `datAppOnTheGlassesUpdateRequired`, use the official update route before retesting.

- [ ] **Step 4: Run the consented end-to-end test**

Observe and record evidence for:

1. One tap and one consent confirmation.
2. **Identifying…** appears visually.
3. Exactly one `target: true` POST reaches the backend.
4. No periodic capture POSTs follow.
5. Name card appears when PimEyes resolves.
6. Direct LinkedIn role updates the same card when available.
7. Card clears after three seconds.
8. Failure shows **Not identified** for three seconds.

- [ ] **Step 5: Verify external prerequisites honestly**

If PimEyes cookies or a paid capability are absent, mark identity lookup blocked while still recording successful one-shot capture, single POST, polling, and display failure-card behavior. Do not claim name/job success without a live authenticated result.

- [ ] **Step 6: Final verification and commit any test-derived fixes**

Re-run full backend tests, full iOS tests, signed build, `git diff --check`, and a secret scan over tracked files. Commit only verified fixes with conventional commit messages.

### Phase 6 gate

Independent auditor reviews automated output and physical-device evidence. User decides whether to land the WAR branch. No merge occurs without the auditor pass and explicit user approval.

---

## Plan Self-Review Results

- Spec coverage: every UX, display timing, one-shot, strict LinkedIn, cancellation, privacy, and verification requirement maps to Tasks 2–10.
- Scope: backend request/enrichment and iOS capture/display are coupled by one explicit contract and fit one phased plan.
- Type consistency: `request_id`, `IdentificationStatusResponse`, `IdentificationTicket`, and the display presenter methods are named consistently across producers and consumers.
- Completeness scan: every step names its files, commands, expected outcome, and neighboring interface.
