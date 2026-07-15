import Foundation
import MWDATCore
import MWDATDisplay

@MainActor protocol IdentityDisplayConnection: AnyObject {
  func send(_ card: IdentityDisplayCard) async throws
  func clear() async throws
  func stop()
}

@MainActor
final class DisplayClearToken {
  private(set) var isCancelled = false
  private var cancellation: (() -> Void)?
  init(cancellation: (() -> Void)? = nil) { self.cancellation = cancellation }
  func installCancellation(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    cancellation?()
    cancellation = nil
  }
}

@MainActor protocol DisplayClearScheduling: AnyObject {
  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> DisplayClearToken
}

@MainActor
final class TaskDisplayClearScheduler: DisplayClearScheduling {
  func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> DisplayClearToken {
    let token = DisplayClearToken()
    let task = Task { @MainActor in
      do { try await Task.sleep(for: delay) }
      catch { return }
      guard !token.isCancelled else { return }
      action()
    }
    token.installCancellation { task.cancel() }
    return token
  }
}

@MainActor
final class SerializedIdentityDisplayLane {
  private let display: any IdentityDisplayConnection
  private var currentGeneration = 0
  private var tail: Task<Void, Never>?

  init(display: any IdentityDisplayConnection) { self.display = display }

  func advance(to generation: Int) { currentGeneration = generation }

  func send(_ card: IdentityDisplayCard, generation: Int) async throws {
    try await enqueue { [weak self] in
      guard let self, self.currentGeneration == generation else { return }
      try await self.display.send(card)
    }
  }

  func clear(generation: Int) async throws {
    try await enqueue { [weak self] in
      guard let self, self.currentGeneration == generation else { return }
      try await self.display.clear()
    }
  }

  func stop(generation: Int) {
    currentGeneration = generation
    let previous = tail
    tail = Task { @MainActor [display] in
      await previous?.value
      display.stop()
    }
  }

  private func enqueue(_ mutation: @escaping @MainActor () async throws -> Void) async throws {
    let previous = tail
    let operation = Task { @MainActor in
      await previous?.value
      try Task.checkCancellation()
      try await mutation()
    }
    tail = Task { _ = try? await operation.value }
    try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }
}

@MainActor
final class GlassesDisplayPresenter {
  private let lane: SerializedIdentityDisplayLane
  private let scheduler: any DisplayClearScheduling
  private var clearToken: DisplayClearToken?
  private var generation = 0

  init(
    display: any IdentityDisplayConnection,
    scheduler: (any DisplayClearScheduling)? = nil
  ) {
    self.lane = SerializedIdentityDisplayLane(display: display)
    self.scheduler = scheduler ?? TaskDisplayClearScheduler()
  }

  func showIdentifying() async throws { try await show(.identifying, clears: false) }
  func showName(_ name: String) async throws { try await show(.name(name), clears: true) }
  func showEnriched(name: String, role: String, company: String) async throws {
    try await show(.enriched(name: name, role: role, company: company), clears: true)
  }
  func showNotIdentified() async throws { try await show(.notIdentified, clears: true) }

  func clear() async throws {
    generation += 1
    let clearGeneration = generation
    lane.advance(to: clearGeneration)
    clearToken?.cancel()
    clearToken = nil
    try await lane.clear(generation: clearGeneration)
  }

  func cancel() {
    generation += 1
    lane.advance(to: generation)
    clearToken?.cancel()
    clearToken = nil
    lane.stop(generation: generation)
  }

  private func show(_ card: IdentityDisplayCard, clears: Bool) async throws {
    generation += 1
    let cardGeneration = generation
    lane.advance(to: cardGeneration)
    clearToken?.cancel()
    clearToken = nil
    try await lane.send(card, generation: cardGeneration)
    guard clears else { return }
    clearToken = scheduler.schedule(after: .seconds(3)) { [weak self] in
      guard let self, self.generation == cardGeneration else { return }
      Task { @MainActor in
        try? await self.lane.clear(generation: cardGeneration)
        if self.generation == cardGeneration { self.clearToken = nil }
      }
    }
  }
}

@MainActor protocol IdentityDisplaySessionFactory: AnyObject {
  func makeDisplaySession() throws -> any IdentityDisplaySessionResource
}

@MainActor protocol IdentityDisplaySessionResource: AnyObject {
  func start() async throws
  func makeDisplay() throws -> any IdentityDisplayCapabilityResource
  func stop()
}

@MainActor protocol IdentityDisplayCapabilityResource: AnyObject {
  func start() async throws
  func send(_ card: IdentityDisplayCard) async throws
  func clear() async throws
  func stop()
}

enum IdentityDisplayConnectionError: Error {
  case cancelled
  case stoppedBeforeReady
  case timedOut
}

@MainActor
final class DATIdentityDisplayConnection: IdentityDisplayConnection {
  private struct Attempt {
    let session: any IdentityDisplaySessionResource
    var display: (any IdentityDisplayCapabilityResource)?
  }

  private let factory: any IdentityDisplaySessionFactory
  private let timeout: Duration
  private var activeSession: (any IdentityDisplaySessionResource)?
  private var activeDisplay: (any IdentityDisplayCapabilityResource)?
  private var attempts: [UUID: Attempt] = [:]
  private var currentAttempt: UUID?

  init(factory: any IdentityDisplaySessionFactory, timeout: Duration = .seconds(15)) {
    self.factory = factory
    self.timeout = timeout
  }

  convenience init(wearables: WearablesInterface, timeout: Duration = .seconds(15)) {
    self.init(factory: DATIdentityDisplaySessionFactory(wearables: wearables), timeout: timeout)
  }

  func send(_ card: IdentityDisplayCard) async throws {
    let display = try await readyDisplay()
    try await display.send(card)
  }

  func clear() async throws {
    guard let activeDisplay else { return }
    try await activeDisplay.clear()
  }

  func stop() {
    currentAttempt = nil
    for token in Array(attempts.keys) { cleanupAttempt(token) }
    activeDisplay?.stop()
    activeDisplay = nil
    activeSession?.stop()
    activeSession = nil
  }

  private func readyDisplay() async throws -> any IdentityDisplayCapabilityResource {
    if let activeDisplay { return activeDisplay }

    // A newer startup attempt supersedes every pending attempt. Cleanup is
    // exact: each attempt owns only the resources stored under its UUID.
    for token in Array(attempts.keys) { cleanupAttempt(token) }
    let token = UUID()
    currentAttempt = token

    do {
      let session = try factory.makeDisplaySession()
      attempts[token] = Attempt(session: session, display: nil)
      let display = try await withThrowingTaskGroup(of: (any IdentityDisplayCapabilityResource).self) { group in
        group.addTask { @MainActor [weak self] in
          guard let self else { throw IdentityDisplayConnectionError.cancelled }
          return try await self.establishAttempt(token)
        }
        group.addTask { @MainActor [weak self, timeout] in
          try await Task.sleep(for: timeout)
          self?.cleanupAttempt(token)
          throw IdentityDisplayConnectionError.timedOut
        }
        defer { group.cancelAll() }
        guard let display = try await group.next() else {
          throw IdentityDisplayConnectionError.stoppedBeforeReady
        }
        return display
      }
      guard currentAttempt == token, let attempt = attempts.removeValue(forKey: token) else {
        throw IdentityDisplayConnectionError.cancelled
      }
      currentAttempt = nil
      activeSession = attempt.session
      activeDisplay = display
      return display
    } catch {
      cleanupAttempt(token)
      if currentAttempt == token { currentAttempt = nil }
      throw error
    }
  }

  private func establishAttempt(_ token: UUID) async throws -> any IdentityDisplayCapabilityResource {
    guard let attempt = attempts[token] else { throw IdentityDisplayConnectionError.cancelled }
    try await attempt.session.start()
    try Task.checkCancellation()
    guard currentAttempt == token, attempts[token] != nil else {
      throw IdentityDisplayConnectionError.cancelled
    }
    let display = try attempt.session.makeDisplay()
    attempts[token]?.display = display
    try await display.start()
    try Task.checkCancellation()
    guard currentAttempt == token, attempts[token] != nil else {
      throw IdentityDisplayConnectionError.cancelled
    }
    return display
  }

  private func cleanupAttempt(_ token: UUID) {
    guard let attempt = attempts.removeValue(forKey: token) else { return }
    attempt.display?.stop()
    attempt.session.stop()
  }
}

@MainActor
private final class DATIdentityDisplaySessionFactory: IdentityDisplaySessionFactory {
  private let wearables: WearablesInterface
  init(wearables: WearablesInterface) { self.wearables = wearables }
  func makeDisplaySession() throws -> any IdentityDisplaySessionResource {
    let selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
    return DATIdentityDisplaySession(
      session: try wearables.createSession(deviceSelector: selector))
  }
}

@MainActor
private final class DATIdentityDisplaySession: IdentityDisplaySessionResource {
  private let session: DeviceSession
  private var stopped = false
  init(session: DeviceSession) { self.session = session }
  func start() async throws {
    let states = session.stateStream()
    try session.start()
    if session.state == .started { return }
    for await state in states {
      if state == .started { return }
      if state == .stopped { throw IdentityDisplayConnectionError.stoppedBeforeReady }
    }
    if Task.isCancelled { throw CancellationError() }
    throw IdentityDisplayConnectionError.stoppedBeforeReady
  }
  func makeDisplay() throws -> any IdentityDisplayCapabilityResource {
    DATIdentityDisplayCapability(display: try session.addDisplay())
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    session.stop()
  }
}

@MainActor
private final class DATIdentityDisplayCapability: IdentityDisplayCapabilityResource {
  private let display: Display
  private var stopped = false
  init(display: Display) { self.display = display }
  func start() async throws {
    let channel = AsyncStream.makeStream(of: DisplayState.self)
    let listener = display.statePublisher.listen { channel.continuation.yield($0) }
    defer { _ = listener; channel.continuation.finish() }
    display.start()
    if display.state == .started { return }
    for await state in channel.stream {
      if state == .started { return }
      if state == .stopped { throw IdentityDisplayConnectionError.stoppedBeforeReady }
    }
    if Task.isCancelled { throw CancellationError() }
    throw IdentityDisplayConnectionError.stoppedBeforeReady
  }
  func send(_ card: IdentityDisplayCard) async throws {
    try await display.send(IdentifyPersonDisplayCard.make(card))
  }
  func clear() async throws { try await display.clearDisplay() }
  func stop() {
    guard !stopped else { return }
    stopped = true
    display.stop()
  }
}
