import Foundation
import MWDATCamera
import MWDATCore
import UIKit

enum ManagedDeviceSessionState: Sendable {
  case started
  case stopped
  case other
}

struct ManagedSessionFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

enum DeviceStreamLifecycleError: Error {
  case noStream
  case sessionStopped
  case timedOut
}

@MainActor
protocol DeviceSessionFactory: AnyObject {
  func makeSession() throws -> any DeviceSessionResource
}

@MainActor
protocol DeviceSessionResource: AnyObject {
  var state: ManagedDeviceSessionState { get }
  var states: AsyncStream<ManagedDeviceSessionState> { get }
  var errors: AsyncStream<ManagedSessionFailure> { get }
  func start() throws
  func stop()
  func makeStream() throws -> (any CameraStreamResource)?
}

@MainActor
protocol CameraStreamResource: AnyObject {
  func start() throws
  func stop()
  func clearListeners()
  func capturePhoto() -> Bool
}

struct CameraStreamCallbacks {
  let onState: @MainActor (StreamState) -> Void
  let onFrame: @MainActor (UIImage) -> Void
  let onPhoto: @MainActor (UIImage) -> Void
  let onError: @MainActor (StreamError) -> Void
}

@MainActor
final class DeviceStreamSessionManager {
  private let factory: any DeviceSessionFactory
  private let timeout: Duration
  private var session: (any DeviceSessionResource)?
  private var stream: (any CameraStreamResource)?
  private var attemptID: UUID?

  var hasSession: Bool { session != nil }
  var hasStream: Bool { stream != nil }

  init(factory: any DeviceSessionFactory, timeout: Duration = .seconds(15)) {
    self.factory = factory
    self.timeout = timeout
  }

  isolated deinit {
    stop()
  }

  func start() async throws {
    stop()
    let attemptID = UUID()
    self.attemptID = attemptID
    let newSession: any DeviceSessionResource
    do {
      newSession = try factory.makeSession()
    } catch {
      self.attemptID = nil
      throw error
    }
    session = newSession
    var newStream: (any CameraStreamResource)?

    do {
      let states = newSession.states
      let errors = newSession.errors
      try newSession.start()
      if newSession.state != .started {
        try await waitUntilStarted(states: states, errors: errors)
      }
      try Task.checkCancellation()
      guard self.attemptID == attemptID else { throw CancellationError() }

      guard let createdStream = try newSession.makeStream() else {
        throw DeviceStreamLifecycleError.noStream
      }
      newStream = createdStream
      stream = createdStream
      try createdStream.start()
      try Task.checkCancellation()
    } catch {
      if let newStream {
        stopStreamOnce(newStream)
      }
      stopSessionOnce(newSession)
      if self.attemptID == attemptID {
        stream = nil
        session = nil
        self.attemptID = nil
      }
      throw error
    }
  }

  func stop() {
    attemptID = nil
    if let stream {
      stopStreamOnce(stream)
      self.stream = nil
    }
    if let session {
      stopSessionOnce(session)
      self.session = nil
    }
  }

  @discardableResult
  func capturePhoto() -> Bool {
    stream?.capturePhoto() ?? false
  }

  private func stopStreamOnce(_ stream: any CameraStreamResource) {
    stream.clearListeners()
    stream.stop()
  }

  private func stopSessionOnce(_ session: any DeviceSessionResource) {
    session.stop()
  }

  private func waitUntilStarted(
    states: AsyncStream<ManagedDeviceSessionState>,
    errors: AsyncStream<ManagedSessionFailure>
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in states {
          if state == .started { return }
          if state == .stopped { throw DeviceStreamLifecycleError.sessionStopped }
        }
        if !Task.isCancelled { throw DeviceStreamLifecycleError.sessionStopped }
      }
      group.addTask {
        for await error in errors { throw error }
        if !Task.isCancelled { throw DeviceStreamLifecycleError.sessionStopped }
      }
      group.addTask { [timeout] in
        try await Task.sleep(for: timeout)
        throw DeviceStreamLifecycleError.timedOut
      }

      defer { group.cancelAll() }
      guard try await group.next() != nil else {
        throw DeviceStreamLifecycleError.sessionStopped
      }
    }
  }
}

@MainActor
final class DATDeviceSessionFactory: DeviceSessionFactory {
  private let wearables: WearablesInterface
  private let selector: AutoDeviceSelector
  private let callbacks: CameraStreamCallbacks

  init(
    wearables: WearablesInterface,
    selector: AutoDeviceSelector,
    callbacks: CameraStreamCallbacks
  ) {
    self.wearables = wearables
    self.selector = selector
    self.callbacks = callbacks
  }

  func makeSession() throws -> any DeviceSessionResource {
    DATDeviceSessionResource(
      session: try wearables.createSession(deviceSelector: selector),
      callbacks: callbacks)
  }
}

@MainActor
private final class DATDeviceSessionResource: DeviceSessionResource {
  private let session: DeviceSession
  private let callbacks: CameraStreamCallbacks
  private var isStopped = false

  init(session: DeviceSession, callbacks: CameraStreamCallbacks) {
    self.session = session
    self.callbacks = callbacks
  }

  var state: ManagedDeviceSessionState { map(session.state) }

  var states: AsyncStream<ManagedDeviceSessionState> {
    let source = session.stateStream()
    return AsyncStream { continuation in
      let task = Task {
        for await state in source { continuation.yield(map(state)) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  var errors: AsyncStream<ManagedSessionFailure> {
    let source = session.errorStream()
    return AsyncStream { continuation in
      let task = Task {
        for await error in source {
          continuation.yield(ManagedSessionFailure(message: error.localizedDescription))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func start() throws { try session.start() }
  func stop() {
    guard !isStopped else { return }
    isStopped = true
    session.stop()
  }

  func makeStream() throws -> (any CameraStreamResource)? {
    let config = StreamConfiguration(
      videoCodec: .raw,
      resolution: .low,
      frameRate: 24)
    guard let stream = try session.addStream(config: config) else { return nil }
    return DATCameraStreamResource(stream: stream, callbacks: callbacks)
  }

  private func map(_ state: DeviceSessionState) -> ManagedDeviceSessionState {
    if state == .started { return .started }
    if state == .stopped { return .stopped }
    return .other
  }
}

@MainActor
private final class DATCameraStreamResource: CameraStreamResource {
  private let stream: MWDATCamera.Stream
  private let callbacks: CameraStreamCallbacks
  private var stateToken: AnyListenerToken?
  private var frameToken: AnyListenerToken?
  private var photoToken: AnyListenerToken?
  private var errorToken: AnyListenerToken?
  private var isStopped = false

  init(stream: MWDATCamera.Stream, callbacks: CameraStreamCallbacks) {
    self.stream = stream
    self.callbacks = callbacks
    installListeners()
  }

  func start() throws { stream.start() }
  func stop() {
    guard !isStopped else { return }
    isStopped = true
    stream.stop()
  }
  func capturePhoto() -> Bool { stream.capturePhoto(format: .jpeg) }

  func clearListeners() {
    stateToken = nil
    frameToken = nil
    photoToken = nil
    errorToken = nil
  }

  private func installListeners() {
    stateToken = stream.statePublisher.listen { [callbacks] state in
      Task { @MainActor in callbacks.onState(state) }
    }
    frameToken = stream.videoFramePublisher.listen { [callbacks] frame in
      guard let image = frame.makeUIImage() else { return }
      Task { @MainActor in callbacks.onFrame(image) }
    }
    photoToken = stream.photoDataPublisher.listen { [callbacks] photo in
      guard let image = UIImage(data: photo.data) else { return }
      Task { @MainActor in callbacks.onPhoto(image) }
    }
    errorToken = stream.errorPublisher.listen { [callbacks] error in
      Task { @MainActor in callbacks.onError(error) }
    }
  }
}
