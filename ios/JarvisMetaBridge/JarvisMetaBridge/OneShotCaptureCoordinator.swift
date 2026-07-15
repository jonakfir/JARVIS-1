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

enum DisplayDeviceReadinessError: Error, LocalizedError, Equatable {
  case timedOut
  var errorDescription: String? {
    "No display-capable Meta glasses became available. Keep the glasses on and connected, then try again."
  }
}

@MainActor protocol DisplayDeviceSelectorReadiness: AnyObject {
  var hasEligibleDevice: Bool { get }
  func availabilityStream() -> AsyncStream<Bool>
}

extension DisplayDeviceSelectorReadiness {
  func waitForEligibleDevice(timeout: Duration) async throws {
    if hasEligibleDevice { return }
    let updates = availabilityStream()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await available in updates where available { return }
        try Task.checkCancellation()
        throw DisplayDeviceReadinessError.timedOut
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw DisplayDeviceReadinessError.timedOut
      }
      defer { group.cancelAll() }
      guard try await group.next() != nil else { throw DisplayDeviceReadinessError.timedOut }
    }
  }
}

@MainActor
final class DATAutoDeviceSelectorReadiness: DisplayDeviceSelectorReadiness {
  let selector: AutoDeviceSelector
  init(wearables: WearablesInterface) {
    selector = AutoDeviceSelector(wearables: wearables) { $0.supportsDisplay() }
  }
  var hasEligibleDevice: Bool { selector.activeDevice != nil }
  func availabilityStream() -> AsyncStream<Bool> {
    let channel = AsyncStream<Bool>.makeStream()
    let source = selector.activeDeviceStream()
    Task {
      for await device in source {
        channel.continuation.yield(device != nil)
        if Task.isCancelled { break }
      }
      channel.continuation.finish()
    }
    return channel.stream
  }
}

@MainActor protocol OneShotCaptureSessionFactory: AnyObject {
  func makeDisplayCapableSession() async throws -> any OneShotCaptureSession
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
      try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { @MainActor in
          let session = try await factory.makeDisplayCapableSession()
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
          try await Self.waitForStreaming(states)
          try Task.checkCancellation()
          guard madeStream.captureJPEG() else { throw OneShotCaptureError.photoRejected }
          return try await madeStream.nextPhoto()
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw OneShotCaptureError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw OneShotCaptureError.streamEnded }
        return result
      }
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

  private static func waitForStreaming(_ states: AsyncStream<OneShotStreamState>) async throws {
    for await state in states where state == .streaming { return }
    if Task.isCancelled { throw CancellationError() }
    throw OneShotCaptureError.streamEnded
  }

}

@MainActor
final class DATOneShotCaptureSessionFactory: OneShotCaptureSessionFactory {
  private let wearables: WearablesInterface
  // AutoDeviceSelector learns about devices asynchronously. Retain it from app
  // setup so it is populated before a user starts a one-shot capture.
  private let readiness: DATAutoDeviceSelectorReadiness
  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.readiness = DATAutoDeviceSelectorReadiness(wearables: wearables)
  }
  func makeDisplayCapableSession() async throws -> any OneShotCaptureSession {
    try await readiness.waitForEligibleDevice(timeout: .seconds(10))
    return DATOneShotCaptureSession(
      session: try wearables.createSession(deviceSelector: readiness.selector))
  }
}

@MainActor
private final class DATOneShotCaptureSession: OneShotCaptureSession {
  private let session: DeviceSession
  private var stopped = false
  init(session: DeviceSession) { self.session = session }

  func start() async throws {
    let states = session.stateStream()
    let errors = session.errorStream()
    try session.start()
    if session.state == .started { return }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in states {
          if state == .started { return }
          if state == .stopped { throw DeviceStreamLifecycleError.sessionStopped }
        }
        throw DeviceStreamLifecycleError.sessionStopped
      }
      group.addTask {
        for await error in errors { throw error }
        throw DeviceStreamLifecycleError.sessionStopped
      }
      defer { group.cancelAll() }
      guard try await group.next() != nil else { throw DeviceStreamLifecycleError.sessionStopped }
    }
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
