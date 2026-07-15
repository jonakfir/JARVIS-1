import Foundation
import MWDATCamera
import MWDATCore

enum OneShotStreamState: Sendable {
  case streaming
  case other
}

enum OneShotCaptureError: Error, Sendable, Equatable {
  case photoRejected
  case streamEnded
  case timedOut
}

@MainActor protocol OneShotCaptureSessionFactory: AnyObject {
  func makeDisplayCapableSession() throws -> any OneShotCaptureSession
}

@MainActor protocol OneShotCaptureSession: AnyObject {
  func start() async throws
  func makeStream() throws -> any OneShotPhotoStream
  func stop()
}

@MainActor protocol OneShotPhotoStream: AnyObject {
  var states: AsyncStream<OneShotStreamState> { get }
  func start() throws
  func captureJPEG() -> Bool
  func nextPhoto() async throws -> Data
  func stop()
}

@MainActor
final class OneShotCaptureCoordinator {
  private let factory: any OneShotCaptureSessionFactory
  private let timeout: Duration
  private var activeTask: Task<Data, Error>?
  private var activeToken: UUID?

  init(factory: any OneShotCaptureSessionFactory, timeout: Duration = .seconds(15)) {
    self.factory = factory
    self.timeout = timeout
  }

  func captureJPEG() async throws -> Data {
    cancel()
    let token = UUID()
    activeToken = token
    let task = Task { @MainActor [factory, timeout] in
      let session = try factory.makeDisplayCapableSession()
      var stream: (any OneShotPhotoStream)?
      defer {
        stream?.stop()
        session.stop()
      }
      try await session.start()
      try Task.checkCancellation()
      let madeStream = try session.makeStream()
      stream = madeStream
      let states = madeStream.states
      try madeStream.start()
      try await Self.waitForStreaming(states, timeout: timeout)
      try Task.checkCancellation()
      guard madeStream.captureJPEG() else { throw OneShotCaptureError.photoRejected }
      return try await Self.waitForPhoto(madeStream, timeout: timeout)
    }
    activeTask = task
    defer {
      if activeToken == token {
        activeTask = nil
        activeToken = nil
      }
    }
    return try await task.value
  }

  func cancel() {
    activeTask?.cancel()
    activeTask = nil
    activeToken = nil
  }

  private static func waitForStreaming(
    _ states: AsyncStream<OneShotStreamState>, timeout: Duration
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in states where state == .streaming { return }
        throw OneShotCaptureError.streamEnded
      }
      group.addTask { try await Task.sleep(for: timeout); throw OneShotCaptureError.timedOut }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private static func waitForPhoto(_ stream: any OneShotPhotoStream, timeout: Duration) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await stream.nextPhoto() }
      group.addTask { try await Task.sleep(for: timeout); throw OneShotCaptureError.timedOut }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw OneShotCaptureError.streamEnded }
      return result
    }
  }
}

@MainActor
final class DATOneShotCaptureSessionFactory: OneShotCaptureSessionFactory {
  private let wearables: WearablesInterface
  init(wearables: WearablesInterface) { self.wearables = wearables }
  func makeDisplayCapableSession() throws -> any OneShotCaptureSession {
    let selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
    return DATOneShotCaptureSession(session: try wearables.createSession(deviceSelector: selector))
  }
}

@MainActor
private final class DATOneShotCaptureSession: OneShotCaptureSession {
  private let session: DeviceSession
  private var stopped = false
  init(session: DeviceSession) { self.session = session }

  func start() async throws {
    let states = session.stateStream()
    try session.start()
    if session.state == .started { return }
    for await state in states {
      if state == .started { return }
      if state == .stopped { throw DeviceStreamLifecycleError.sessionStopped }
    }
    throw DeviceStreamLifecycleError.sessionStopped
  }

  func makeStream() throws -> any OneShotPhotoStream {
    let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)
    guard let stream = try session.addStream(config: config) else { throw DeviceStreamLifecycleError.noStream }
    return DATOneShotPhotoStream(stream: stream)
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    session.stop()
  }
}

@MainActor
private final class DATOneShotPhotoStream: OneShotPhotoStream {
  private let stream: MWDATCamera.Stream
  private var stateToken: AnyListenerToken?
  private var photoToken: AnyListenerToken?
  private let stateChannel = AsyncStream<OneShotStreamState>.makeStream()
  private var bufferedPhoto: Data?
  private var photoWaiter: (UUID, CheckedContinuation<Data, Error>)?
  private var stopped = false

  init(stream: MWDATCamera.Stream) {
    self.stream = stream
    stateToken = stream.statePublisher.listen { [stateChannel] state in
      stateChannel.continuation.yield(state == .streaming ? .streaming : .other)
    }
    photoToken = stream.photoDataPublisher.listen { [weak self] photo in
      Task { @MainActor in self?.receive(photo.data) }
    }
    // Intentionally no videoFramePublisher subscription: one-shot photos only.
  }

  var states: AsyncStream<OneShotStreamState> { stateChannel.stream }
  func start() throws { stream.start() }
  func captureJPEG() -> Bool { stream.capturePhoto(format: .jpeg) }
  func nextPhoto() async throws -> Data {
    if let bufferedPhoto {
      self.bufferedPhoto = nil
      return bufferedPhoto
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { photoWaiter = (id, continuation) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiter(id: id) }
    }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    stateToken = nil
    photoToken = nil
    resumeWaiter(throwing: OneShotCaptureError.streamEnded)
    stream.stop()
  }

  private func receive(_ data: Data) {
    guard let (_, waiter) = photoWaiter else {
      bufferedPhoto = data
      return
    }
    photoWaiter = nil
    waiter.resume(returning: data)
  }

  private func cancelWaiter(id: UUID) {
    guard photoWaiter?.0 == id else { return }
    resumeWaiter(throwing: CancellationError())
  }

  private func resumeWaiter(throwing error: Error) {
    guard let (_, waiter) = photoWaiter else { return }
    photoWaiter = nil
    waiter.resume(throwing: error)
  }
}
