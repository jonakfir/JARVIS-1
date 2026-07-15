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
final class GlassesDisplayPresenter {
  private let display: any IdentityDisplayConnection
  private let scheduler: any DisplayClearScheduling
  private var clearToken: DisplayClearToken?
  private var generation = 0

  init(
    display: any IdentityDisplayConnection,
    scheduler: (any DisplayClearScheduling)? = nil
  ) {
    self.display = display
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
    clearToken?.cancel()
    clearToken = nil
    try await display.clear()
  }

  func cancel() {
    generation += 1
    clearToken?.cancel()
    clearToken = nil
    display.stop()
  }

  private func show(_ card: IdentityDisplayCard, clears: Bool) async throws {
    generation += 1
    let cardGeneration = generation
    clearToken?.cancel()
    clearToken = nil
    try await display.send(card)
    guard clears else { return }
    clearToken = scheduler.schedule(after: .seconds(3)) { [weak self] in
      guard let self, self.generation == cardGeneration else { return }
      Task { @MainActor in
        guard self.generation == cardGeneration else { return }
        try? await self.display.clear()
        if self.generation == cardGeneration { self.clearToken = nil }
      }
    }
  }
}

@MainActor
final class DATIdentityDisplayConnection: IdentityDisplayConnection {
  private let wearables: WearablesInterface
  private var session: DeviceSession?
  private var display: Display?

  init(wearables: WearablesInterface) { self.wearables = wearables }

  func send(_ card: IdentityDisplayCard) async throws {
    let display = try await readyDisplay()
    try await display.send(IdentifyPersonDisplayCard.make(card))
  }

  func clear() async throws {
    guard let display else { return }
    try await display.clearDisplay()
  }

  func stop() {
    display?.stop()
    display = nil
    session?.stop()
    session = nil
  }

  private func readyDisplay() async throws -> Display {
    if let display, display.state == .started { return display }
    stop()
    let selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
    let session = try wearables.createSession(deviceSelector: selector)
    self.session = session
    let sessionStates = session.stateStream()
    try session.start()
    if session.state != .started {
      for await state in sessionStates {
        if state == .started { break }
        if state == .stopped { throw DeviceStreamLifecycleError.sessionStopped }
      }
    }
    let display = try session.addDisplay()
    let (states, continuation) = AsyncStream.makeStream(of: DisplayState.self)
    let token = display.statePublisher.listen { continuation.yield($0) }
    defer { _ = token; continuation.finish() }
    display.start()
    if display.state != .started {
      for await state in states {
        if state == .started { break }
        if state == .stopped { throw DeviceStreamLifecycleError.sessionStopped }
      }
    }
    self.display = display
    return display
  }
}
