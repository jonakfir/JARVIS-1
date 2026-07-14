# Meta Glasses PimEyes Identification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the explicit Identify Person flow from Ray-Ban Meta glasses through the iOS bridge and JARVIS to the existing PimEyes searcher.

**Architecture:** Normal glasses frames continue through `POST /api/capture/frame` with `target: false`; one explicit user action sends the current frame with `target: true`. The backend selects the largest detected bounding box, runs one asynchronous search, and exposes terminal errors; the iOS uploader remains pending until a later polling response reports success/failure or a 90-second timeout expires.

**Tech Stack:** Python 3.12, FastAPI, Pydantic, pytest, Swift 6, SwiftUI, URLSession async/await, Meta Wearables DAT iOS 0.4.0 (`MWDATCore`, `MWDATCamera`), Xcode 16+

## Global Constraints

- Preserve every non-Identify-Person iOS widget without modification.
- Keep Meta DAT pinned to exact version `0.4.0` and use only APIs confirmed by `samples/CameraAccess`.
- Normal streaming sends at most one frame per second, prevents overlap, uses source `meta_glasses_ios`, and always sends `target: false`.
- Only the explicit, consent-gated Identify Person action sends `target: true`.
- Never commit Google credentials, PimEyes credentials, browser cookies, or session tokens.
- Use `backend/identification/pimeyes_cookies.json` for the local Google-authenticated session; it must remain gitignored.
- Execute this plan through the repository-required WorkAuditRefine WAR workflow with phase gates and independent audit before merge.
- Preserve unrelated pre-existing worktree changes and never stage them in task commits.

---

### Task 1: Make the Backend Identification Contract Observable and Deterministic

**Files:**
- Modify: `backend/schemas.py:57-64`
- Modify: `backend/capture/frame_handler.py:21-31,93-110`
- Modify: `backend/tests/test_capture.py`

**Interfaces:**
- Consumes: `FrameHandler.process_frame(frame_b64: str, timestamp: int, source: str, target: bool) -> dict`
- Produces: identification dictionaries with `track_id`, `status`, `name`, `person_id`, and optional `error`; largest-bounding-box selection for `target: true`

- [ ] **Step 1: Add failing serialization and target-selection tests**

Add focused tests to `backend/tests/test_capture.py` using the existing fixtures/mocks. The assertions must cover both requirements:

```python
def test_identification_to_dict_includes_error() -> None:
    identification = Identification(track_id=7)
    identification.status = "failed"
    identification.error = "PimEyes cookies expired"

    assert identification.to_dict() == {
        "track_id": 7,
        "status": "failed",
        "name": None,
        "person_id": None,
        "error": "PimEyes cookies expired",
    }


@pytest.mark.asyncio
async def test_target_uses_largest_bbox_not_largest_encoded_crop(monkeypatch) -> None:
    handler = make_configured_frame_handler()
    detections = [
        {"bbox": [0.0, 0.0, 20.0, 20.0], "confidence": 0.99, "track_id": 1},
        {"bbox": [0.0, 0.0, 80.0, 100.0], "confidence": 0.90, "track_id": 2},
    ]
    monkeypatch.setattr(handler.detector, "detect_from_base64", lambda _: {"detections": detections})
    monkeypatch.setattr(handler.detector, "crop_persons", lambda *_: ["a" * 500, "b" * 100])

    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)

    assert handler._identifications[2].track_id == 2
    assert 1 not in handler._identifications
```

Adapt `make_configured_frame_handler` and `VALID_FRAME_B64` to the existing test helpers instead of duplicating fixtures.

- [ ] **Step 2: Run the focused tests and confirm they fail for the intended reasons**

Run:

```bash
cd backend
uv run pytest tests/test_capture.py -q
```

Expected: the error-field assertion fails because `Identification.to_dict()` omits `error`; the selection test fails because the implementation chooses the largest encoded crop.

- [ ] **Step 3: Extend the response schema and internal serialization**

Change the Pydantic model in `backend/schemas.py` to:

```python
class Identification(BaseModel):
    track_id: int
    status: str
    name: str | None = None
    person_id: str | None = None
    error: str | None = None
```

Change `backend/capture/frame_handler.py` serialization to:

```python
def to_dict(self) -> dict:
    return {
        "track_id": self.track_id,
        "status": self.status,
        "name": self.name,
        "person_id": self.person_id,
        "error": self.error,
    }
```

- [ ] **Step 4: Select the target by bounding-box area**

Replace the encoded-length comparison with a small local helper and aligned index:

```python
def bbox_area(detection: dict) -> float:
    x1, y1, x2, y2 = detection["bbox"]
    return max(0.0, x2 - x1) * max(0.0, y2 - y1)

best_idx = max(range(len(detections)), key=lambda index: bbox_area(detections[index]))
crop_b64 = crops[best_idx]
det = detections[best_idx]
```

Before using the shared index, guard against detector/crop count mismatch. If counts differ, log an error and do not start identification for that frame; never select a mismatched crop.

- [ ] **Step 5: Add failure-lock regression coverage**

Add or refine an async test that awaits the spawned identification task and asserts the lock is reusable after search failure:

```python
@pytest.mark.asyncio
async def test_search_failure_releases_identification_lock(...) -> None:
    searcher.search_face.return_value = FaceSearchResult(success=False, error="expired")
    await handler.process_frame(VALID_FRAME_B64, 1, "meta_glasses_ios", target=True)
    await wait_until(lambda: handler._identifications[TRACK_ID].status == "failed")

    assert handler._search_in_progress is False
    assert handler._identifications[TRACK_ID].error == "No matches found"
```

Use the current deterministic async-test pattern already present in the file; do not add sleeps longer than required for the scheduled task to yield.

- [ ] **Step 6: Run backend verification**

Run:

```bash
cd backend
uv run pytest tests/test_capture.py tests/test_face_search.py -q
uv run ruff check schemas.py capture/frame_handler.py tests/test_capture.py
```

Expected: all selected tests pass and Ruff reports no errors.

- [ ] **Step 7: Commit only Task 1 files**

```bash
git add backend/schemas.py backend/capture/frame_handler.py backend/tests/test_capture.py
git commit -m "fix: harden targeted face identification"
```

---

### Task 2: Track the Full Asynchronous Identification Lifecycle on iOS

**Files:**
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/JarvisFrameUploader.swift`
- Modify: `ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift`
- Modify only if source membership changes are necessary: `ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `FrameProcessedResponse.identifications[*].status/error/name`, stream responses from `submit(image:)`, and explicit trigger from `identify(image:)`
- Produces: `isIdentifying`, `identifyStatus`, and terminal error/name UI that reflect the backend job rather than only the trigger HTTP request

- [ ] **Step 1: Record the current compile baseline with workspace-local build artifacts**

Run:

```bash
xcodebuild \
  -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .scratch/xcode-derived-data \
  -clonedSourcePackagesDirPath .scratch/swift-packages \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: either `BUILD SUCCEEDED`, or a concrete pre-existing compiler/package error recorded before edits. If dependency resolution is blocked by network access, rerun only after obtaining the required network approval.

- [ ] **Step 2: Extend the Swift wire model**

Add the backend's optional error field without breaking responses that omit it:

```swift
struct Identification: Decodable {
  let trackId: Int
  let status: String
  let name: String?
  let personId: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case trackId = "track_id"
    case status
    case name
    case personId = "person_id"
    case error
  }
}
```

- [ ] **Step 3: Replace the request-only lock with a backend-job lock**

Keep upload overlap protection separate from identification lifecycle state. Add:

```swift
private var identificationTimeoutTask: Task<Void, Never>?
private let identificationTimeout: Duration = .seconds(90)
```

At the start of `identify(image:)`, set `isIdentifying = true` and `identifyStatus = "Requesting identification…"`. Do not clear `isIdentifying` in a `defer`. If the trigger request fails or returns no identification in progress, clear it immediately with an actionable status. If accepted, set `identifyStatus = "Identifying…"` and schedule the timeout:

```swift
private func startIdentificationTimeout() {
  identificationTimeoutTask?.cancel()
  identificationTimeoutTask = Task { [weak self] in
    try? await Task.sleep(for: self?.identificationTimeout ?? .seconds(90))
    guard !Task.isCancelled else { return }
    self?.isIdentifying = false
    self?.identifyStatus = "Timed out — tap Identify to retry"
  }
}
```

Because the uploader is `@MainActor`, keep all published-property mutations main-actor isolated.

- [ ] **Step 4: Reconcile every successful response with job state**

Call a helper after decoding both `submit(image:)` and `identify(image:)` responses:

```swift
private func updateIdentificationState(from response: FrameProcessedResponse) {
  guard let latest = response.identifications.last else { return }

  switch latest.status {
  case "identifying":
    isIdentifying = true
    identifyStatus = "Identifying person…"
    startIdentificationTimeout()
  case "identified":
    identificationTimeoutTask?.cancel()
    isIdentifying = false
    identifyStatus = latest.name.map { "Identified: \($0)" } ?? "Identified"
  case "failed":
    identificationTimeoutTask?.cancel()
    isIdentifying = false
    identifyStatus = latest.error.map { "Failed: \($0)" } ?? "Identification failed"
  default:
    break
  }
}
```

Do not reset the 90-second timer on each polling response. Start it only when entering `identifying` from a non-identifying state, otherwise a continuous stream could postpone timeout forever.

- [ ] **Step 5: Make `target` impossible to accidentally vary in each public path**

Retain a private shared request function if useful, but construct the two payloads with explicit constants at the call sites:

```swift
return await perform(image: image, target: false) // submit(image:)
return await perform(image: image, target: true)  // identify(image:)
```

Run a source audit after editing:

```bash
rg -n 'target:\s*(true|false)|identify\(image' ios/JarvisMetaBridge/JarvisMetaBridge
```

Expected: `target: true` appears only in the explicit Identify Person uploader path and explanatory comments; normal frame submission is `false`.

- [ ] **Step 6: Show actionable terminal state in the existing Identify Person UI**

Keep the button disabled with the existing `uploader.isIdentifying` check. Update the identification row to prefer the decoded error when failed:

```swift
private func identLabel(_ ident: FrameProcessedResponse.Identification) -> String {
  if ident.status == "failed", let error = ident.error, !error.isEmpty {
    return "failed · \(error)"
  }
  if let name = ident.name, !name.isEmpty {
    return "\(ident.status) · \(name)"
  }
  return ident.status
}
```

Do not edit any other widget view.

- [ ] **Step 7: Compile and inspect Meta API usage**

Run the workspace-local build command from Step 1, then compare the Meta calls:

```bash
diff -u \
  samples/CameraAccess/CameraAccess/ViewModels/WearablesViewModel.swift \
  ios/JarvisMetaBridge/JarvisMetaBridge/WearablesViewModel.swift || true
rg -n 'Wearables|StreamSession|AutoDeviceSelector|Permission\.camera|makeUIImage' \
  ios/JarvisMetaBridge/JarvisMetaBridge \
  samples/CameraAccess/CameraAccess
```

Expected: `BUILD SUCCEEDED`; every SDK symbol used by the bridge is present in the pinned package's official sample or package interface.

- [ ] **Step 8: Commit only Identify Person iOS files**

```bash
git add \
  ios/JarvisMetaBridge/JarvisMetaBridge/JarvisFrameUploader.swift \
  ios/JarvisMetaBridge/JarvisMetaBridge/IdentifyPersonWidgetView.swift
git commit -m "fix: track PimEyes identification on iOS"
```

Include `project.pbxproj` only if the implementation genuinely required a membership change.

---

### Task 3: Document and Validate the Google-Authenticated PimEyes Path

**Files:**
- Modify: `ios/JarvisMetaBridge/README.md`
- Modify: `README.md`
- Modify: `.env.example` only if necessary to remove misleading password guidance
- Test: `.gitignore`

**Interfaces:**
- Consumes: local file path `backend/identification/pimeyes_cookies.json` and existing `PimEyesSearcher._load_cookies()` support for Cookie-Editor list JSON or name/value dictionary JSON
- Produces: reproducible setup instructions for the Google-login account without storing credentials

- [ ] **Step 1: Verify the secret path is ignored**

Run:

```bash
git check-ignore -v backend/identification/pimeyes_cookies.json
```

Expected: `.gitignore` reports the `pimeyes_cookies.json` rule. If it does not, add the exact path to `.gitignore` before continuing.

- [ ] **Step 2: Add exact Google-login cookie setup instructions**

Document these steps in the Identify Person/PimEyes section of `ios/JarvisMetaBridge/README.md` and the backend configuration section of `README.md`:

```text
1. Open an incognito/private browser window and sign into https://pimeyes.com using Continue with Google for jonakfir@gmail.com.
2. Confirm a PimEyes search works manually in that browser session.
3. Export only pimeyes.com cookies as JSON using a trusted cookie-export extension.
4. Save the export as backend/identification/pimeyes_cookies.json.
5. Never commit or share this file; it grants access to the authenticated PimEyes session.
6. Restart the backend after replacing the file because cookies are cached in memory.
7. If JARVIS reports expired/unauthorized cookies, repeat the export from a fresh authenticated session.
```

State explicitly that `PIMEYES_EMAIL`/`PIMEYES_PASSWORD` do not reproduce Google OAuth login and should be left blank for this account.

- [ ] **Step 3: Add backend and iPhone run instructions without altering unrelated widget docs**

Ensure the Identify Person instructions include:

```bash
cd backend
uv sync
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Also include `ipconfig getifaddr en0` for the Mac Wi-Fi address, the app URL format `http://<mac-ip>:8000`, physical-iPhone signing steps, Meta callback values from `Config/JarvisMetaBridge.xcconfig`, and the manual sequence Connect → grant camera → Start Stream → consent → Identify.

- [ ] **Step 4: Run documentation and credential-safety checks**

Run:

```bash
git diff --check
git check-ignore -v backend/identification/pimeyes_cookies.json
rg -n 'jonakfir@gmail\.com|PIMEYES_PASSWORD|pimeyes_cookies' README.md ios/JarvisMetaBridge/README.md .env.example .gitignore
git ls-files | rg 'pimeyes_cookies|\.env$' && exit 1 || true
```

Expected: no whitespace errors; the cookie file is ignored and untracked; documentation contains no password, cookie value, token, or Google credential.

- [ ] **Step 5: Commit only documentation/configuration files intentionally changed by this task**

```bash
git add README.md ios/JarvisMetaBridge/README.md
git commit -m "docs: explain Google-authenticated PimEyes setup"
```

Add `.env.example` or `.gitignore` only if Step 1-2 required a correction.

---

### Task 4: Full Scoped Verification and Diff Audit

**Files:**
- Review only: every file committed by Tasks 1-3
- Do not modify unrelated dirty files

**Interfaces:**
- Consumes: completed backend, iOS, and documentation changes
- Produces: evidence that the scoped path builds, tests, matches the wire contract, and preserves unrelated work

- [ ] **Step 1: Run the backend suite relevant to capture and face search**

```bash
cd backend
uv run pytest tests/test_capture.py tests/test_face_search.py tests/test_identify_endpoint.py -q
uv run ruff check schemas.py capture/frame_handler.py tests/test_capture.py
```

Expected: all selected tests pass and Ruff reports no errors.

- [ ] **Step 2: Build the iOS project**

```bash
xcodebuild \
  -project ios/JarvisMetaBridge/JarvisMetaBridge.xcodeproj \
  -scheme JarvisMetaBridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .scratch/xcode-derived-data \
  -clonedSourcePackagesDirPath .scratch/swift-packages \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Audit request/response parity and target call sites**

```bash
rg -n 'class FrameSubmission|class FrameProcessedResponse|class Identification' backend/schemas.py
rg -n 'struct FrameProcessedResponse|struct FrameSubmission|target:\s*(true|false)' \
  ios/JarvisMetaBridge/JarvisMetaBridge/JarvisFrameUploader.swift
```

Expected: Python and Swift fields agree; the stream path is false and the explicit Identify path is true.

- [ ] **Step 4: Review only the scoped commit range and verify unrelated files remain unstaged**

```bash
git diff --check HEAD~3..HEAD
git diff --stat HEAD~3..HEAD
git status --short
```

Expected: the commit range contains only Task 1-3 files; pre-existing unrelated modifications remain unstaged and unchanged.

- [ ] **Step 5: Perform the repository-required independent WAR auditor pass**

The auditor must verify backend correctness, Swift compile safety, Meta SDK symbol provenance, credential hygiene, `target` call-site safety, and preservation of unrelated widgets. Resolve every blocking finding and rerun Steps 1-4 before requesting merge approval.

