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
  func makeSession(token: UUID) throws -> any DeviceSessionResource
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
  let onState: @MainActor (UUID, StreamState) -> Void
  let onFrame: @MainActor (UUID, UIImage) -> Void
  let onPhoto: @MainActor (UUID, UIImage) -> Void
  let onError: @MainActor (UUID, StreamError) -> Void
}

@MainActor
final class DeviceStreamSessionManager {
  private let factory: any DeviceSessionFactory
  private let timeout: Duration
  private var session: (any DeviceSessionResource)?
  private var stream: (any CameraStreamResource)?
  private var sessionObserverTask: Task<Void, Never>?
  private let onSessionTerminated: @MainActor (UUID, ManagedSessionFailure?) -> Void

  var hasSession: Bool { session != nil }
  var hasStream: Bool { stream != nil }
  private(set) var activeToken: UUID?

  init(
    factory: any DeviceSessionFactory,
    timeout: Duration = .seconds(15),
    onSessionTerminated: @escaping @MainActor (UUID, ManagedSessionFailure?) -> Void = { _, _ in }
  ) {
    self.factory = factory
    self.timeout = timeout
    self.onSessionTerminated = onSessionTerminated
  }

  isolated deinit {
    stop()
  }

  func start() async throws {
    stop()
    let token = UUID()
    activeToken = token
    let newSession: any DeviceSessionResource
    do {
      newSession = try factory.makeSession(token: token)
    } catch {
      activeToken = nil
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
      guard activeToken == token else { throw CancellationError() }

      guard let createdStream = try newSession.makeStream() else {
        throw DeviceStreamLifecycleError.noStream
      }
      newStream = createdStream
      stream = createdStream
      let ongoingStates = newSession.states
      let ongoingErrors = newSession.errors
      try createdStream.start()
      try Task.checkCancellation()
      guard activeToken == token else { throw CancellationError() }
      observeSession(token: token, states: ongoingStates, errors: ongoingErrors)
    } catch {
      if let newStream {
        stopStreamOnce(newStream)
      }
      stopSessionOnce(newSession)
      if activeToken == token {
        stream = nil
        session = nil
        activeToken = nil
        sessionObserverTask?.cancel()
        sessionObserverTask = nil
      }
      throw error
    }
  }

  func stop() {
    activeToken = nil
    sessionObserverTask?.cancel()
    sessionObserverTask = nil
    if let stream {
      stopStreamOnce(stream)
      self.stream = nil
    }
    if let session {
      stopSessionOnce(session)
      self.session = nil
    }
  }

  func stop(token: UUID) {
    guard activeToken == token else { return }
    stop()
  }

  func owns(token: UUID) -> Bool {
    activeToken == token
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

  private func observeSession(
    token: UUID,
    states: AsyncStream<ManagedDeviceSessionState>,
    errors: AsyncStream<ManagedSessionFailure>
  ) {
    sessionObserverTask?.cancel()
    sessionObserverTask = Task { @MainActor [weak self] in
      let failure = await Self.waitForTerminalState(states: states, errors: errors)
      guard let self, self.activeToken == token else { return }
      self.stop(token: token)
      self.onSessionTerminated(token, failure)
    }
  }

  private static func waitForTerminalState(
    states: AsyncStream<ManagedDeviceSessionState>,
    errors: AsyncStream<ManagedSessionFailure>
  ) async -> ManagedSessionFailure? {
    await withTaskGroup(of: ManagedSessionFailure?.self) { group in
      group.addTask {
        for await state in states where state == .stopped { return nil }
        return nil
      }
      group.addTask {
        for await error in errors { return error }
        return nil
      }
      let result = await group.next() ?? nil
      group.cancelAll()
      return result
    }
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

  func makeSession(token: UUID) throws -> any DeviceSessionResource {
    DATDeviceSessionResource(
      session: try wearables.createSession(deviceSelector: selector),
      callbacks: callbacks,
      token: token)
  }
}

@MainActor
private final class DATDeviceSessionResource: DeviceSessionResource {
  private let session: DeviceSession
  private let callbacks: CameraStreamCallbacks
  private let token: UUID
  private var isStopped = false

  init(session: DeviceSession, callbacks: CameraStreamCallbacks, token: UUID) {
    self.session = session
    self.callbacks = callbacks
    self.token = token
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
    return DATCameraStreamResource(stream: stream, callbacks: callbacks, token: token)
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
  private let token: UUID
  private var stateToken: AnyListenerToken?
  private var frameToken: AnyListenerToken?
  private var photoToken: AnyListenerToken?
  private var errorToken: AnyListenerToken?
  private var isStopped = false

  init(stream: MWDATCamera.Stream, callbacks: CameraStreamCallbacks, token: UUID) {
    self.stream = stream
    self.callbacks = callbacks
    self.token = token
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
    let generation = token
    stateToken = stream.statePublisher.listen { [callbacks, generation] state in
      Task { @MainActor in callbacks.onState(generation, state) }
    }
    frameToken = stream.videoFramePublisher.listen { [callbacks, generation] frame in
      guard let image = frame.makeUIImage() else { return }
      Task { @MainActor in callbacks.onFrame(generation, image) }
    }
    photoToken = stream.photoDataPublisher.listen { [callbacks, generation] photo in
      guard let image = UIImage(data: photo.data) else { return }
      Task { @MainActor in callbacks.onPhoto(generation, image) }
    }
    errorToken = stream.errorPublisher.listen { [callbacks, generation] error in
      Task { @MainActor in callbacks.onError(generation, error) }
    }
  }
}
