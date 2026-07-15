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
}

@MainActor private final class FakeIdentityDisplay: IdentityDisplayConnection {
  private(set) var cards: [IdentityDisplayCard] = []
  private(set) var clearCount = 0
  func send(_ card: IdentityDisplayCard) async throws { cards.append(card) }
  func clear() async throws { clearCount += 1 }
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
