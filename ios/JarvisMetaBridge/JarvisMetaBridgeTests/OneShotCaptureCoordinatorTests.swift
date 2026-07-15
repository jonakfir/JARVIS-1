import XCTest
@testable import JarvisMetaBridge

@MainActor
final class OneShotCaptureCoordinatorTests: XCTestCase {
  func testDeviceReadinessWaitsForDelayedEligibleDevice() async throws {
    let selector = FakeDeviceReadinessSelector()
    let wait = Task { try await selector.waitForEligibleDevice(timeout: .seconds(1)) }
    await Task.yield()
    selector.emit(true)
    try await wait.value
  }

  func testDeviceReadinessTimesOutWhenNoEligibleDeviceAppears() async {
    let selector = FakeDeviceReadinessSelector()
    await XCTAssertThrowsErrorAsync {
      try await selector.waitForEligibleDevice(timeout: .milliseconds(20))
    }
  }

  func testDeviceReadinessCancellationReturnsPromptly() async {
    let selector = FakeDeviceReadinessSelector()
    let wait = Task { try await selector.waitForEligibleDevice(timeout: .seconds(10)) }
    await Task.yield()
    wait.cancel()
    await XCTAssertThrowsErrorAsync { try await wait.value }
  }

  func testDeviceReadinessReusesCurrentEligibleStateWithoutNewStream() async throws {
    let selector = FakeDeviceReadinessSelector(hasEligibleDevice: true)
    try await selector.waitForEligibleDevice(timeout: .seconds(1))
    try await selector.waitForEligibleDevice(timeout: .seconds(1))
    XCTAssertEqual(selector.streamCount, 0)
  }

  func testCaptureStartsDisplaySessionAndStreamCapturesOnceThenCleansUp() async throws {
    let stream = FakeOneShotStream()
    let session = FakeOneShotSession(stream: stream)
    let factory = FakeOneShotFactory(session: session)
    let coordinator = OneShotCaptureCoordinator(factory: factory, timeout: .seconds(1))

    let task = Task { try await coordinator.captureJPEG() }
    await waitUntil { stream.startCount == 1 }
    stream.emitState(.streaming)
    await waitUntil { stream.captureCount == 1 }
    stream.emitPhoto(Data([1, 2, 3]))

    let jpeg = try await task.value
    XCTAssertEqual(jpeg, Data([1, 2, 3]))
    XCTAssertEqual(factory.makeCount, 1)
    XCTAssertEqual(session.startCount, 1)
    XCTAssertEqual(stream.captureCount, 1)
    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(session.stopCount, 1)
    XCTAssertEqual(stream.videoFrameSubscriptionCount, 0)
  }

  func testCapturePhotoRejectionCleansUp() async {
    let stream = FakeOneShotStream(captureAccepted: false)
    let session = FakeOneShotSession(stream: stream)
    let coordinator = OneShotCaptureCoordinator(factory: FakeOneShotFactory(session: session), timeout: .seconds(1))

    let task = Task { try await coordinator.captureJPEG() }
    await waitUntil { stream.startCount == 1 }
    stream.emitState(.streaming)

    await XCTAssertThrowsErrorAsync { _ = try await task.value }
    XCTAssertEqual(stream.captureCount, 1)
    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(session.stopCount, 1)
  }

  func testCancelStopsPendingCaptureAndResources() async {
    let stream = FakeOneShotStream()
    let session = FakeOneShotSession(stream: stream)
    let coordinator = OneShotCaptureCoordinator(factory: FakeOneShotFactory(session: session), timeout: .seconds(10))
    let task = Task { try await coordinator.captureJPEG() }
    await waitUntil { stream.startCount == 1 }

    coordinator.cancel()

    await XCTAssertThrowsErrorAsync { _ = try await task.value }
    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(session.stopCount, 1)
  }

  func testTimeoutStopsResourcesWithoutCapturing() async {
    let stream = FakeOneShotStream()
    let session = FakeOneShotSession(stream: stream)
    let coordinator = OneShotCaptureCoordinator(factory: FakeOneShotFactory(session: session), timeout: .milliseconds(20))

    await XCTAssertThrowsErrorAsync { _ = try await coordinator.captureJPEG() }

    XCTAssertEqual(stream.captureCount, 0)
    XCTAssertEqual(stream.stopCount, 1)
    XCTAssertEqual(session.stopCount, 1)
  }
}

@MainActor private final class FakeDeviceReadinessSelector: DisplayDeviceSelectorReadiness {
  var hasEligibleDevice: Bool
  private let channel = AsyncStream<Bool>.makeStream()
  private(set) var streamCount = 0
  init(hasEligibleDevice: Bool = false) { self.hasEligibleDevice = hasEligibleDevice }
  func availabilityStream() -> AsyncStream<Bool> {
    streamCount += 1
    return channel.stream
  }
  func emit(_ available: Bool) {
    hasEligibleDevice = available
    channel.continuation.yield(available)
  }
}

@MainActor private final class FakeOneShotFactory: OneShotCaptureSessionFactory {
  let session: FakeOneShotSession
  private(set) var makeCount = 0
  init(session: FakeOneShotSession) { self.session = session }
  func makeDisplayCapableSession() async throws -> any OneShotCaptureSession {
    makeCount += 1
    return session
  }
}

@MainActor private final class FakeOneShotSession: OneShotCaptureSession {
  let stream: FakeOneShotStream
  private(set) var startCount = 0
  private(set) var stopCount = 0
  init(stream: FakeOneShotStream) { self.stream = stream }
  func start() async throws { startCount += 1 }
  func makeStream() throws -> any OneShotPhotoStream { stream }
  func stop() { stopCount += 1 }
}

@MainActor private final class FakeOneShotStream: OneShotPhotoStream {
  private let stateChannel = AsyncStream<OneShotStreamState>.makeStream()
  private let photoChannel = AsyncStream<Data>.makeStream()
  let captureAccepted: Bool
  private(set) var startCount = 0
  private(set) var captureCount = 0
  private(set) var stopCount = 0
  let videoFrameSubscriptionCount = 0
  var states: AsyncStream<OneShotStreamState> { stateChannel.stream }
  init(captureAccepted: Bool = true) { self.captureAccepted = captureAccepted }
  func start() throws { startCount += 1 }
  func captureJPEG() -> Bool { captureCount += 1; return captureAccepted }
  func nextPhoto() async throws -> Data {
    for await photo in photoChannel.stream { return photo }
    throw OneShotCaptureError.streamEnded
  }
  func stop() { stopCount += 1 }
  func emitState(_ state: OneShotStreamState) { stateChannel.continuation.yield(state) }
  func emitPhoto(_ data: Data) { photoChannel.continuation.yield(data) }
}

@MainActor private func waitUntil(_ predicate: @escaping () -> Bool) async {
  for _ in 0..<100 where !predicate() { await Task.yield() }
}

private extension XCTestCase {
  func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch {}
  }
}
