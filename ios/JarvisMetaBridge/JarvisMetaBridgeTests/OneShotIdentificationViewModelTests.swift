import XCTest
@testable import JarvisMetaBridge

@MainActor
final class OneShotIdentificationViewModelTests: XCTestCase {
  func testOneAttemptCapturesAndSubmitsOnceThenShowsNameBeforeEnrichment() async {
    let harness = IdentificationHarness(results: [
      .fixture(status: .identifying),
      .fixture(status: .identified, name: "Jane Doe"),
      .fixture(status: .identified, name: "Jane Doe", job: "Engineer", company: "Acme")
    ])
    let model = harness.makeModel()

    model.startIdentification()
    await harness.waitUntilFinished(model)

    XCTAssertEqual(harness.captureCount, 1)
    XCTAssertEqual(harness.submitCount, 1)
    XCTAssertEqual(harness.cards, [.identifying, .name("Jane Doe"),
      .enriched(name: "Jane Doe", role: "Engineer", company: "Acme")])
    XCTAssertEqual(model.state, .enrichedCardDisplayed(name: "Jane Doe", role: "Engineer", company: "Acme"))
  }

  func testCameraCaptureCompletesBeforeDisplaySessionStarts() async {
    let harness = IdentificationHarness(results: [.fixture(status: .failed, error: "none")])
    harness.suspendCapture = true
    let model = harness.makeModel()

    model.startIdentification()
    await harness.waitUntil { harness.captureCount == 1 }
    XCTAssertTrue(harness.cards.isEmpty)

    harness.suspendCapture = false
    await harness.waitUntilFinished(model)
    XCTAssertEqual(harness.cards, [.identifying, .notIdentified])
  }

  func testDuplicateTapIsIgnored() async {
    let harness = IdentificationHarness(results: [.fixture(status: .failed, error: "none")])
    harness.suspendCapture = true
    let model = harness.makeModel()
    model.startIdentification()
    model.startIdentification()
    await Task.yield()
    XCTAssertEqual(harness.captureCount, 1)
    model.cancel()
  }

  func testFailureShowsNotIdentifiedAndDiagnostic() async {
    let harness = IdentificationHarness(results: [.fixture(status: .failed, error: "PimEyes unavailable")])
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntilFinished(model)
    XCTAssertEqual(harness.cards, [.identifying, .notIdentified])
    XCTAssertEqual(model.state, .notIdentified)
    XCTAssertEqual(model.diagnosticMessage, "PimEyes unavailable")
  }

  func testNameOnlyAtDeadlineRemainsSuccessful() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identified, name: "Jane Doe")])
    harness.advanceSecondsPerSleep = 91
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntilFinished(model)
    XCTAssertEqual(harness.cards, [.identifying, .name("Jane Doe")])
    XCTAssertEqual(model.state, .nameDisplayed("Jane Doe"))
  }

  func testTimeoutBeforeNameShowsNotIdentified() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identifying)])
    harness.advanceSecondsPerSleep = 91
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntilFinished(model)
    XCTAssertEqual(harness.cards, [.identifying, .notIdentified])
    XCTAssertEqual(model.state, .notIdentified)
  }

  func testCancellationTearsDownCaptureDisplayAndPolling() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identifying)])
    harness.suspendCapture = true
    let model = harness.makeModel()
    model.startIdentification()
    await Task.yield()
    model.cancel()
    await Task.yield()
    XCTAssertEqual(harness.captureCancelCount, 1)
    XCTAssertEqual(harness.displayCancelCount, 1)
    XCTAssertEqual(model.state, .idle)
  }

  func testCancelWhileIdentifyingCardIsSuspendedDoesNotAdvanceAfterCapture() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identifying)])
    harness.suspendIdentifyingCard = true
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntil { harness.cards == [.identifying] }

    model.cancel()
    harness.suspendIdentifyingCard = false
    await Task.yield()

    XCTAssertEqual(harness.captureCount, 1)
    XCTAssertEqual(model.state, .idle)
  }

  func testCanceledStatusCannotPublishStaleName() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identified, name: "Old Name")])
    harness.suspendStatus = true
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntil { harness.statusCount == 1 }

    model.cancel()
    harness.suspendStatus = false
    await Task.yield()

    XCTAssertEqual(model.state, .idle)
    XCTAssertFalse(harness.cards.contains(.name("Old Name")))
  }

  func testCanceledAttemptCompletionCannotLoseOwnershipOfImmediateRestart() async {
    let harness = IdentificationHarness(results: [.fixture(status: .identifying)])
    harness.suspendCapture = true
    let model = harness.makeModel()
    model.startIdentification()
    await harness.waitUntil { harness.captureCount == 1 }
    model.cancel()

    model.startIdentification()
    await harness.waitUntil { harness.captureCount == 2 }
    await Task.yield() // allow the canceled first task to finish its cleanup
    model.cancel()

    XCTAssertEqual(harness.captureCancelCount, 2)
    XCTAssertEqual(model.state, .idle)
    XCTAssertFalse(model.isBusy)
  }
}

@MainActor
private final class IdentificationHarness {
  var results: [IdentificationResult]
  var captureCount = 0
  var submitCount = 0
  var statusCount = 0
  var captureCancelCount = 0
  var displayCancelCount = 0
  var cards: [IdentityDisplayCard] = []
  var suspendCapture = false
  var suspendIdentifyingCard = false
  var suspendStatus = false
  var advanceSecondsPerSleep: TimeInterval = 1
  var now = Date(timeIntervalSince1970: 0)

  init(results: [IdentificationResult]) { self.results = results }

  func makeModel() -> OneShotIdentificationViewModel {
    OneShotIdentificationViewModel(
      captureJPEG: { [weak self] in
        guard let self else { throw CancellationError() }
        self.captureCount += 1
        while self.suspendCapture { try await Task.sleep(for: .milliseconds(1)) }
        return Data([1])
      },
      cancelCapture: { [weak self] in self?.captureCancelCount += 1 },
      submit: { [weak self] _ in
        self?.submitCount += 1
        return IdentificationTicket(requestID: "request", trackID: -1)
      },
      status: { [weak self] _ in
        guard let self else { throw CancellationError() }
        let index = min(self.statusCount, self.results.count - 1)
        self.statusCount += 1
        while self.suspendStatus { try await Task.sleep(for: .milliseconds(1)) }
        return self.results[index]
      },
      showCard: { [weak self] card in
        self?.cards.append(card)
        while self?.suspendIdentifyingCard == true && card == .identifying {
          try await Task.sleep(for: .milliseconds(1))
        }
      },
      cancelDisplay: { [weak self] in self?.displayCancelCount += 1 },
      sleep: { [weak self] _ in self?.now.addTimeInterval(self?.advanceSecondsPerSleep ?? 1) },
      now: { [weak self] in self?.now ?? .distantFuture })
  }

  func waitUntilFinished(_ model: OneShotIdentificationViewModel) async {
    for _ in 0..<100 where model.isBusy { await Task.yield() }
  }

  func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() { await Task.yield() }
  }
}

private extension IdentificationResult {
  static func fixture(
    status: IdentificationState, name: String? = nil, job: String? = nil,
    company: String? = nil, error: String? = nil
  ) -> Self {
    .init(requestID: "request", trackID: -1, status: status, name: name,
      linkedinURL: nil, jobTitle: job, company: company, error: error)
  }
}
