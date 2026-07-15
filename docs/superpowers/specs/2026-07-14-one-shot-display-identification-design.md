# One-Shot Display Identification Design

Date: 2026-07-14

## Objective

Change Identify Person from a continuously uploading camera workflow into a deliberate one-shot interaction for Meta Ray-Ban Display glasses. One tap captures one still image, submits one identification request, and presents visual-only results in the glasses display.

## User Experience

1. The user opens Identify Person and taps **Identify Person**.
2. The app presents the existing in-the-moment consent confirmation.
3. After confirmation, the app starts a temporary camera-capable device session if one is not already ready.
4. The app captures exactly one still image through the Meta Wearables Device Access Toolkit photo-capture API.
5. The app stops the temporary camera capability/session after capture. It does not start or retain a periodic frame-upload loop.
6. The app submits the still image once to the JARVIS backend with `target: true`.
7. While processing, the glasses show **Identifying…** until a terminal identification result replaces it.
8. When identification resolves:
   - Show the person's name immediately in one glasses display card.
   - Start or continue LinkedIn enrichment asynchronously.
   - If a directly matched LinkedIn profile yields a current role, update the same card to `Name — Role at Company` and restart its three-second visibility window.
   - If the name-only card has already cleared when enrichment finishes, show the completed `Name — Role at Company` card again for three seconds.
   - If no directly matched LinkedIn role is found, do not guess and do not show a job update.
9. If no person is detected, face search fails, or identification times out, show **Not identified** for three seconds.
10. Clear the result display after its three-second window. Never speak the result.

Only one identification attempt may be active at a time. Repeated taps while an attempt is active are ignored and the action remains visibly disabled.

## SDK and Device Architecture

The iOS project is currently pinned to Meta Wearables DAT 0.4.0. Display output requires the Display-capable DAT architecture introduced in 0.7.0. Implementation will upgrade to the latest compatible stable DAT release available in the package repository at implementation time, migrate camera APIs as required by the changelog, add the `MWDATDisplay` product, and enable the Device Access Toolkit App Model with `MWDAT.DAMEnabled = true`.

The app will create a device session using a selector constrained to a display-capable device. Meta's current photo API requires an active stream capability, so the app briefly starts that capability, captures one JPEG through `capturePhoto(format: .jpeg)`, and stops it after the photo callback. Video frames may exist inside DAT during that short lifecycle but are never submitted to the backend. Camera and display are separate capabilities owned by the same session coordinator:

- `OneShotCaptureCoordinator` owns the temporary still-capture lifecycle and returns JPEG data.
- `GlassesDisplayPresenter` owns display start/send/clear behavior and enforces the three-second presentation window.
- `IdentificationCoordinator` owns the one active request, backend polling, name-first result sequence, LinkedIn update, cancellation, and UI state.

The coordinator boundaries keep SDK lifecycle code separate from backend response interpretation and make each state machine testable.

## Backend Contract

The one-shot submission continues to use `POST /api/capture/frame` with `target: true`, preserving the user requirement that this flag remain enabled for identification. The response must admit an identification with a stable integer `track_id`, including the existing `-1` sentinel when YOLO has not assigned a tracker ID.

The backend identification state exposed to iOS is:

- `identifying`: the one-shot request was accepted.
- `identified`: includes a non-empty `name`; may optionally include `job_title` and `company` when already known.
- `failed`: includes a safe user-facing failure reason for phone diagnostics, while the glasses always show only **Not identified**.

LinkedIn enrichment is best effort and uses only configured, authorized services and publicly available professional information. A job may be displayed only when the face-search evidence includes a LinkedIn profile that directly matches the resolved identity. Name-only LinkedIn search results are too ambiguous and must not be displayed. Enrichment must not delay the initial name card. If the existing polling response cannot carry enrichment separately, add a narrowly scoped result endpoint keyed by the admitted identification/capture ID. The client stops polling after a terminal result or 90 seconds.

PimEyes authentication remains an operational prerequisite for real identity lookup. Missing or expired PimEyes credentials produce a terminal failure rather than silently invoking unrelated reverse-search paths.

## State and Timing

The phone UI uses these explicit states:

- `idle`
- `capturing`
- `identifying`
- `nameDisplayed`
- `enriching`
- `enrichedCardDisplayed`
- `notIdentified`
- `failed`

One-shot capture has a 15-second deadline. Identification and enrichment share a 90-second overall deadline, but the name is displayed as soon as it becomes available. The initial name card clears three seconds after it is sent. An enrichment update replaces or re-presents that same card with both name and role, then starts a fresh three-second clear timer. A newer card cancels the prior clear task so an old timer cannot erase a newer result.

Stopping the screen, disconnecting the glasses, or starting a new valid attempt cancels outstanding tasks and clears the display.

## Error Handling

- No display-capable device: show an actionable phone error; do not fall back to audio.
- Camera permission missing: request through Meta AI, then require the user to tap again after permission returns.
- Still capture failure or timeout: show **Not identified** for three seconds when display is available and retain diagnostic detail on the phone.
- Backend unavailable: show **Not identified** and retain the endpoint/network error on the phone.
- No person or face: show **Not identified**.
- PimEyes missing, expired, or rejected: show **Not identified** and report the credential problem on the phone.
- LinkedIn role unavailable: keep the successful name result and omit the job card.
- Display send failure: report it on the phone only; never use speech as a fallback.

## Privacy and Safety Constraints

- Identification remains a deliberate, user-initiated action behind the existing confirmation that the subject consented.
- Exactly one still image is uploaded per confirmed attempt.
- No background or periodic identification is permitted.
- The ordinary detection stream is removed from this interaction rather than repurposed for identification.
- Results are transient on the display and are not spoken.
- Client tokens remain in the ignored local xcconfig file and are not committed.

## Verification

Automated verification will cover:

- One tap produces one capture and one `target: true` backend submission.
- No periodic uploader starts during one-shot identification.
- A name is displayed before LinkedIn enrichment completes.
- A card is updated with a job only when the face-search evidence supplies a directly matching LinkedIn profile and a useful current role.
- A late LinkedIn result re-presents the combined name-and-job card for three seconds.
- Each card clears after three seconds, and stale clear tasks cannot erase newer cards.
- Failure paths display **Not identified** and never invoke audio.
- Null YOLO tracking IDs serialize as the integer sentinel.
- Cancellation tears down camera/display capabilities and polling.

Integration verification will include a signed physical-iPhone build, Meta AI registration, real still capture from Meta Ray-Ban Display, a live backend request, and visual display delivery. PimEyes and LinkedIn success tests require valid configured sessions; their absence is reported as an unmet external prerequisite, not treated as a passing identity test.

## Out of Scope

- Continuous video upload or automatic identification.
- Spoken results.
- Persistent on-glasses identity history.
- Scraping private LinkedIn data or bypassing authentication controls.
- Identifying without the subject's explicit consent.
