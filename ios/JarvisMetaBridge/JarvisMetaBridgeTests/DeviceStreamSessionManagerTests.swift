import XCTest
@testable import JarvisMetaBridge

@MainActor
final class DeviceStreamSessionManagerTests: XCTestCase {
  func testStartupErrorTearsDownSession() async {
    let session = FakeDeviceSession(startError: TestFailure())
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await manager.start() }

    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
    XCTAssertFalse(manager.hasStream)
  }

  func testAsyncStartupErrorTearsDownSession() async {
    let session = FakeDeviceSession(asyncError: ManagedSessionFailure(message: "link lost"))
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await manager.start() }

    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
  }

  func testAddStreamFailureTearsDownSession() async {
    let session = FakeDeviceSession(initialState: .started, addStreamError: TestFailure())
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await manager.start() }

    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
  }

  func testStreamStartFailureStopsBothResources() async {
    let stream = FakeCameraStream(startError: TestFailure())
    let session = FakeDeviceSession(initialState: .started, stream: stream)
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await manager.start() }

    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasStream)
  }

  func testTimeoutTearsDownPendingSession() async {
    let session = FakeDeviceSession()
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .milliseconds(10))

    await XCTAssertThrowsErrorAsync { try await manager.start() }

    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
  }

  func testCancellationTearsDownPendingSession() async {
    let session = FakeDeviceSession()
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(10))
    let task = Task { try await manager.start() }
    await Task.yield()
    task.cancel()

    await XCTAssertThrowsErrorAsync { try await task.value }

    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
  }

  func testRetryDoesNotRetainFailedSession() async throws {
    let failed = FakeDeviceSession(startError: TestFailure())
    let stream = FakeCameraStream()
    let succeeded = FakeDeviceSession(initialState: .started, stream: stream)
    let factory = FakeFactory(sessions: [failed, succeeded])
    let manager = DeviceStreamSessionManager(factory: factory, timeout: .seconds(1))

    await XCTAssertThrowsErrorAsync { try await manager.start() }
    try await manager.start()

    XCTAssertEqual(failed.stopCount, 1)
    XCTAssertEqual(factory.createCount, 2)
    XCTAssertTrue(manager.hasSession)
    XCTAssertTrue(manager.hasStream)
  }

  func testRetryWhileStartupIsPendingStopsOldSessionOnlyOnce() async throws {
    let pending = FakeDeviceSession()
    let replacementStream = FakeCameraStream()
    let replacement = FakeDeviceSession(initialState: .started, stream: replacementStream)
    let manager = DeviceStreamSessionManager(
      factory: FakeFactory(sessions: [pending, replacement]),
      timeout: .milliseconds(20))
    let firstAttempt = Task { try await manager.start() }
    await Task.yield()

    try await manager.start()
    await XCTAssertThrowsErrorAsync { try await firstAttempt.value }

    XCTAssertEqual(pending.stopCount, 1)
    XCTAssertTrue(manager.hasSession)
    XCTAssertTrue(manager.hasStream)
  }

  func testStopIsIdempotentAndClearsListeners() async throws {
    let stream = FakeCameraStream()
    let session = FakeDeviceSession(initialState: .started, stream: stream)
    let manager = DeviceStreamSessionManager(factory: FakeFactory(sessions: [session]), timeout: .seconds(1))
    try await manager.start()

    manager.stop()
    manager.stop()

    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(stream.clearListenersCount, 1)
    XCTAssertEqual(session.stopCount, 1)
    XCTAssertFalse(manager.hasSession)
    XCTAssertFalse(manager.hasStream)
  }

  func testQueuedOldStreamStopCannotStopReplacement() async throws {
    let old = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let replacement = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let manager = DeviceStreamSessionManager(
      factory: FakeFactory(sessions: [old, replacement]), timeout: .seconds(1))
    try await manager.start()
    let oldToken = try XCTUnwrap(manager.activeToken)

    try await manager.start()
    let replacementToken = try XCTUnwrap(manager.activeToken)
    manager.stop(token: oldToken)

    XCTAssertNotEqual(oldToken, replacementToken)
    XCTAssertEqual(manager.activeToken, replacementToken)
    XCTAssertTrue(manager.hasSession)
    XCTAssertTrue(manager.hasStream)
  }

  func testPostStartSessionStopClearsMatchingGeneration() async throws {
    let session = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let manager = DeviceStreamSessionManager(
      factory: FakeFactory(sessions: [session]), timeout: .seconds(1))
    try await manager.start()

    session.emitState(.stopped)
    await waitUntil { !manager.hasSession }

    XCTAssertFalse(manager.hasSession)
    XCTAssertFalse(manager.hasStream)
  }

  func testPostStartSessionErrorClearsMatchingGeneration() async throws {
    let session = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let manager = DeviceStreamSessionManager(
      factory: FakeFactory(sessions: [session]), timeout: .seconds(1))
    try await manager.start()

    session.emitError(ManagedSessionFailure(message: "lost"))
    await waitUntil { !manager.hasSession }

    XCTAssertFalse(manager.hasSession)
    XCTAssertFalse(manager.hasStream)
  }

  func testStaleSessionTerminalEventCannotStopReplacement() async throws {
    let old = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let replacement = FakeDeviceSession(initialState: .started, stream: FakeCameraStream())
    let manager = DeviceStreamSessionManager(
      factory: FakeFactory(sessions: [old, replacement]), timeout: .seconds(1))
    try await manager.start()
    try await manager.start()
    let replacementToken = try XCTUnwrap(manager.activeToken)

    old.emitState(.stopped)
    old.emitError(ManagedSessionFailure(message: "stale"))
    await Task.yield()

    XCTAssertEqual(manager.activeToken, replacementToken)
    XCTAssertTrue(manager.hasSession)
    XCTAssertTrue(manager.hasStream)
  }
}

private struct TestFailure: Error {}

@MainActor
private final class FakeFactory: DeviceSessionFactory {
  var sessions: [FakeDeviceSession]
  private(set) var createCount = 0

  init(sessions: [FakeDeviceSession]) { self.sessions = sessions }

  func makeSession(token: UUID) throws -> any DeviceSessionResource {
    defer { createCount += 1 }
    return sessions[createCount]
  }
}

@MainActor
private final class FakeDeviceSession: DeviceSessionResource {
  var state: ManagedDeviceSessionState
  let states: AsyncStream<ManagedDeviceSessionState>
  let errors: AsyncStream<ManagedSessionFailure>
  private let stateContinuation: AsyncStream<ManagedDeviceSessionState>.Continuation
  private let errorContinuation: AsyncStream<ManagedSessionFailure>.Continuation
  var startError: Error?
  var addStreamError: Error?
  var stream: FakeCameraStream?
  private(set) var stopCount = 0
  private var isStopped = false

  init(
    initialState: ManagedDeviceSessionState = .stopped,
    startError: Error? = nil,
    addStreamError: Error? = nil,
    stream: FakeCameraStream? = nil,
    asyncError: ManagedSessionFailure? = nil
  ) {
    self.state = initialState
    self.startError = startError
    self.addStreamError = addStreamError
    self.stream = stream
    let stateChannel = AsyncStream<ManagedDeviceSessionState>.makeStream()
    self.states = stateChannel.stream
    self.stateContinuation = stateChannel.continuation
    let errorChannel = AsyncStream<ManagedSessionFailure>.makeStream()
    self.errors = errorChannel.stream
    self.errorContinuation = errorChannel.continuation
    if let asyncError {
      self.errorContinuation.yield(asyncError)
      self.errorContinuation.finish()
    }
  }

  func start() throws { if let startError { throw startError } }
  func stop() {
    guard !isStopped else { return }
    isStopped = true
    stopCount += 1
  }
  func makeStream() throws -> (any CameraStreamResource)? {
    if let addStreamError { throw addStreamError }
    return stream
  }

  func emitState(_ state: ManagedDeviceSessionState) { stateContinuation.yield(state) }
  func emitError(_ error: ManagedSessionFailure) { errorContinuation.yield(error) }
}

@MainActor
private final class FakeCameraStream: CameraStreamResource {
  var startError: Error?
  private(set) var stopCount = 0
  private(set) var clearListenersCount = 0
  private var isStopped = false

  init(startError: Error? = nil) { self.startError = startError }
  func start() throws { if let startError { throw startError } }
  func stop() {
    guard !isStopped else { return }
    isStopped = true
    stopCount += 1
  }
  func clearListeners() { clearListenersCount += 1 }
  func capturePhoto() -> Bool { false }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<100 {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}
