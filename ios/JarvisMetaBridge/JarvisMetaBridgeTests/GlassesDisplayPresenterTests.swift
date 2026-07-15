import XCTest
@testable import JarvisMetaBridge

@MainActor
final class GlassesDisplayPresenterTests: XCTestCase {
  func testIdentifyingRemainsUntilReplacedAndResultsScheduleThreeSecondClear() async throws {
    let display = FakeIdentityDisplay()
    let scheduler = FakeClearScheduler()
    let presenter = GlassesDisplayPresenter(display: display, scheduler: scheduler)

    try await presenter.showIdentifying()
    XCTAssertEqual(display.cards, [.identifying])
    XCTAssertTrue(scheduler.entries.isEmpty)

    try await presenter.showName("Jane Doe")
    XCTAssertEqual(display.cards.last, .name("Jane Doe"))
    XCTAssertEqual(scheduler.entries.last?.delay, .seconds(3))
  }

  func testUpdateCancelsStaleClearAndStartsFreshThreeSeconds() async throws {
    let display = FakeIdentityDisplay()
    let scheduler = FakeClearScheduler()
    let presenter = GlassesDisplayPresenter(display: display, scheduler: scheduler)
    try await presenter.showName("Jane Doe")
    let old = try XCTUnwrap(scheduler.entries.last)

    try await presenter.showEnriched(name: "Jane Doe", role: "Engineer", company: "Acme")

    XCTAssertTrue(old.token.isCancelled)
    XCTAssertEqual(display.cards.last, .enriched(name: "Jane Doe", role: "Engineer", company: "Acme"))
    old.action()
    await Task.yield()
    XCTAssertEqual(display.clearCount, 0)
    scheduler.entries.last?.action()
    await waitUntil { display.clearCount == 1 }
    XCTAssertEqual(display.clearCount, 1)
  }

  func testLateEnrichmentReappearsAfterNameCleared() async throws {
    let display = FakeIdentityDisplay()
    let scheduler = FakeClearScheduler()
    let presenter = GlassesDisplayPresenter(display: display, scheduler: scheduler)
    try await presenter.showName("Jane Doe")
    scheduler.entries.last?.action()
    await waitUntil { display.clearCount == 1 }

    try await presenter.showEnriched(name: "Jane Doe", role: "Engineer", company: "Acme")

    XCTAssertEqual(display.cards.last, .enriched(name: "Jane Doe", role: "Engineer", company: "Acme"))
    XCTAssertEqual(scheduler.entries.last?.delay, .seconds(3))
  }

  func testNotIdentifiedIsVisualAndClearsAfterThreeSeconds() async throws {
    let display = FakeIdentityDisplay()
    let scheduler = FakeClearScheduler()
    let presenter = GlassesDisplayPresenter(display: display, scheduler: scheduler)

    try await presenter.showNotIdentified()

    XCTAssertEqual(display.cards, [.notIdentified])
    XCTAssertEqual(scheduler.entries.last?.delay, .seconds(3))
  }

  func testSerializedLaneDoesNotResurrectExpiredCardAfterSuspendedStaleSend() async throws {
    let display = FakeIdentityDisplay()
    let lane = SerializedIdentityDisplayLane(display: display)
    lane.advance(to: 1)
    display.suspendNextSend = true
    let stale = Task { try await lane.send(.name("Old"), generation: 1) }
    await waitUntil { display.sendStarted }

    lane.advance(to: 2)
    let current = Task {
      try await lane.send(
        .enriched(name: "Jane Doe", role: "Engineer", company: "Acme"), generation: 2)
    }
    let clear = Task { try await lane.clear(generation: 2) }
    display.resumeSend()

    try await stale.value
    try await current.value
    try await clear.value
    XCTAssertNil(display.visibleCard)
  }

  func testSerializedLaneSuspendedStaleOperationCannotOverwriteNewerCard() async throws {
    let display = FakeIdentityDisplay()
    let lane = SerializedIdentityDisplayLane(display: display)
    lane.advance(to: 1)
    display.suspendNextSend = true
    let stale = Task { try await lane.send(.name("Old"), generation: 1) }
    await waitUntil { display.sendStarted }

    lane.advance(to: 2)
    let current = Task {
      try await lane.send(
        .enriched(name: "Jane Doe", role: "Engineer", company: "Acme"), generation: 2)
    }
    display.resumeSend()

    try await stale.value
    try await current.value
    XCTAssertEqual(display.visibleCard, .enriched(name: "Jane Doe", role: "Engineer", company: "Acme"))
  }

  func testOverlappingStartupOlderCompletionCannotReplaceNewerSession() async throws {
    let old = FakeDisplaySession(suspendStart: true)
    let replacement = FakeDisplaySession()
    let factory = FakeDisplayConnectionFactory(sessions: [old, replacement])
    let connection = DATIdentityDisplayConnection(factory: factory, timeout: .seconds(1))
    let oldSend = Task { try await connection.send(.name("Old")) }
    await waitUntil { old.startCount == 1 }

    try await connection.send(.name("New"))
    old.resumeStart()
    await XCTAssertThrowsErrorAsync { try await oldSend.value }

    XCTAssertEqual(old.stopCount, 1)
    XCTAssertEqual(replacement.stopCount, 0)
    XCTAssertEqual(replacement.capability.cards, [.name("New")])
  }

  func testCancelStopsPendingStartupAttempt() async {
    let session = FakeDisplaySession(suspendStart: true)
    let connection = DATIdentityDisplayConnection(
      factory: FakeDisplayConnectionFactory(sessions: [session]), timeout: .seconds(1))
    let send = Task { try await connection.send(.name("Jane")) }
    await waitUntil { session.startCount == 1 }

    connection.stop()
    session.resumeStart()

    await XCTAssertThrowsErrorAsync { try await send.value }
    XCTAssertEqual(session.stopCount, 1)
  }

  func testSessionAndCapabilityFailuresCleanExactResources() async {
    let startFailure = FakeDisplaySession(startError: TestDisplayError())
    let capabilityFailure = FakeDisplaySession(capabilityStartError: TestDisplayError())
    let factory = FakeDisplayConnectionFactory(sessions: [startFailure, capabilityFailure])
    let connection = DATIdentityDisplayConnection(factory: factory, timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await connection.send(.name("One")) }
    await XCTAssertThrowsErrorAsync { try await connection.send(.name("Two")) }

    XCTAssertEqual(startFailure.stopCount, 1)
    XCTAssertEqual(capabilityFailure.capability.stopCount, 1)
    XCTAssertEqual(capabilityFailure.stopCount, 1)
  }

  func testSessionCreationFailureDoesNotPoisonRetry() async throws {
    let retry = FakeDisplaySession()
    let factory = FakeDisplayConnectionFactory(
      sessions: [retry], errors: [TestDisplayError()])
    let connection = DATIdentityDisplayConnection(factory: factory, timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await connection.send(.name("First")) }
    try await connection.send(.name("Retry"))

    XCTAssertEqual(retry.capability.cards, [.name("Retry")])
    XCTAssertEqual(retry.stopCount, 0)
  }

  func testStartupTimeoutStopsPendingSession() async {
    let session = FakeDisplaySession(suspendStart: true)
    let connection = DATIdentityDisplayConnection(
      factory: FakeDisplayConnectionFactory(sessions: [session]), timeout: .milliseconds(20))

    await XCTAssertThrowsErrorAsync { try await connection.send(.name("Jane")) }

    XCTAssertEqual(session.stopCount, 1)
  }
}

@MainActor private final class FakeIdentityDisplay: IdentityDisplayConnection {
  private(set) var cards: [IdentityDisplayCard] = []
  private(set) var clearCount = 0
  private(set) var visibleCard: IdentityDisplayCard?
  private(set) var clearStarted = false
  private(set) var sendStarted = false
  var suspendNextClear = false
  var suspendNextSend = false
  private var clearContinuation: CheckedContinuation<Void, Never>?
  private var sendContinuation: CheckedContinuation<Void, Never>?
  func send(_ card: IdentityDisplayCard) async throws {
    sendStarted = true
    if suspendNextSend {
      suspendNextSend = false
      await withCheckedContinuation { sendContinuation = $0 }
    }
    cards.append(card)
    visibleCard = card
  }
  func clear() async throws {
    clearStarted = true
    if suspendNextClear {
      suspendNextClear = false
      await withCheckedContinuation { clearContinuation = $0 }
    }
    clearCount += 1
    visibleCard = nil
  }
  func resumeClear() { clearContinuation?.resume(); clearContinuation = nil }
  func resumeSend() { sendContinuation?.resume(); sendContinuation = nil }
  func stop() {}
}

@MainActor private final class FakeClearScheduler: DisplayClearScheduling {
  struct Entry {
    let delay: Duration
    let token: DisplayClearToken
    let action: @MainActor () -> Void
  }
  private(set) var entries: [Entry] = []
  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> DisplayClearToken {
    let token = DisplayClearToken()
    entries.append(Entry(delay: delay, token: token, action: { if !token.isCancelled { action() } }))
    return token
  }
}

@MainActor private func waitUntil(_ predicate: @escaping () -> Bool) async {
  for _ in 0..<100 where !predicate() { await Task.yield() }
}

private struct TestDisplayError: Error {}

@MainActor private final class FakeDisplayConnectionFactory: IdentityDisplaySessionFactory {
  private var sessions: [FakeDisplaySession]
  private var errors: [Error]
  init(sessions: [FakeDisplaySession], errors: [Error] = []) {
    self.sessions = sessions
    self.errors = errors
  }
  func makeDisplaySession() throws -> any IdentityDisplaySessionResource {
    if !errors.isEmpty { throw errors.removeFirst() }
    return sessions.removeFirst()
  }
}

@MainActor private final class FakeDisplaySession: IdentityDisplaySessionResource {
  let capability: FakeDisplayCapability
  let startError: Error?
  let suspendStart: Bool
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var startContinuation: CheckedContinuation<Void, Error>?
  init(
    suspendStart: Bool = false,
    startError: Error? = nil,
    capabilityStartError: Error? = nil
  ) {
    self.suspendStart = suspendStart
    self.startError = startError
    self.capability = FakeDisplayCapability(startError: capabilityStartError)
  }
  func start() async throws {
    startCount += 1
    if let startError { throw startError }
    if suspendStart { try await withCheckedThrowingContinuation { startContinuation = $0 } }
  }
  func makeDisplay() throws -> any IdentityDisplayCapabilityResource { capability }
  func stop() {
    stopCount += 1
    startContinuation?.resume(throwing: CancellationError())
    startContinuation = nil
  }
  func resumeStart() { startContinuation?.resume(); startContinuation = nil }
}

@MainActor private final class FakeDisplayCapability: IdentityDisplayCapabilityResource {
  let startError: Error?
  private(set) var cards: [IdentityDisplayCard] = []
  private(set) var stopCount = 0
  init(startError: Error?) { self.startError = startError }
  func start() async throws { if let startError { throw startError } }
  func send(_ card: IdentityDisplayCard) async throws { cards.append(card) }
  func clear() async throws {}
  func stop() { stopCount += 1 }
}

private extension XCTestCase {
  func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch {}
  }
}
