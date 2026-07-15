//
// StreamSessionViewModel.swift
//
// Drives the glasses camera video stream via the DAT SDK (`MWDATCamera`) and
// forwards each frame to JARVIS through `JarvisFrameUploader`.
//
// Adapted from Meta's official CameraAccess sample — uses only real SDK APIs
// (SDK 0.8.x): DeviceSession, Stream, StreamConfiguration, AutoDeviceSelector,
// VideoCodec.raw, StreamingResolution, StreamState, StreamError,
// Permission.camera, and videoFrame.makeUIImage().
//

import Foundation
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
final class StreamSessionViewModel: ObservableObject {
  // Live preview + status
  @Published var currentVideoFrame: UIImage?
  /// Latest high-resolution still from capturePhoto() (used by Note Buddy).
  @Published var capturedPhoto: UIImage?
  /// Increments on each new captured photo (UIImage isn't Equatable, so views
  /// observe this counter to react to a fresh capture).
  @Published var capturedPhotoVersion: Int = 0
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var hasActiveDevice: Bool = false
  @Published var cameraPermissionGranted: Bool = false
  /// When true, every glasses frame is streamed to JARVIS for person detection
  /// (widget #1). Widgets that only need the live preview (e.g. Scene Describe,
  /// which captures on demand) set this false so they don't spam the backend.
  @Published var detectionUploadsEnabled: Bool = true

  // Errors
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  /// The uploader is shared so the UI can observe upload status/detection counts.
  let uploader: JarvisFrameUploader

  var isStreaming: Bool { streamingStatus != .stopped }

  // DAT SDK plumbing
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var sessionManager: DeviceStreamSessionManager!

  init(wearables: WearablesInterface, uploader: JarvisFrameUploader) {
    self.wearables = wearables
    self.uploader = uploader
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    deviceMonitorTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    let callbacks = CameraStreamCallbacks(
      onState: { [weak self] state in self?.updateStatusFromState(state) },
      onFrame: { [weak self] image in self?.handleVideoFrame(image) },
      onPhoto: { [weak self] image in self?.handlePhoto(image) },
      onError: { [weak self] error in self?.handleStreamError(error) })
    let factory = DATDeviceSessionFactory(
      wearables: wearables,
      selector: deviceSelector,
      callbacks: callbacks)
    self.sessionManager = DeviceStreamSessionManager(factory: factory)
  }

  isolated deinit {
    deviceMonitorTask?.cancel()
    sessionManager?.stop()
  }

  /// Trigger a high-resolution photo. Result arrives on `capturedPhoto`.
  func capturePhoto() {
    sessionManager.capturePhoto()
  }

  // MARK: - Permission

  /// Refresh the cached camera permission status without prompting.
  func refreshPermission() async {
    do {
      let status = try await wearables.checkPermissionStatus(Permission.camera)
      cameraPermissionGranted = (status == .granted)
    } catch {
      cameraPermissionGranted = false
    }
  }

  // MARK: - Streaming lifecycle

  /// Check/request camera permission, then start the glasses stream.
  func startStreaming() async {
    do {
      var status = try await wearables.checkPermissionStatus(Permission.camera)
      if status != .granted {
        status = try await wearables.requestPermission(Permission.camera)
      }
      cameraPermissionGranted = (status == .granted)
      guard status == .granted else {
        show("Camera permission denied. Grant it in the Meta AI app / Settings.")
        return
      }
      try await sessionManager.start()
    } catch {
      show("Unable to start camera: \(error.localizedDescription)")
    }
  }

  func stopStreaming() async {
    sessionManager.stop()
  }

  /// Send the CURRENT frame for a one-shot, consent-gated identification.
  /// Call only from a deliberate user action after the subject has consented.
  func identifyCurrentFrame() async {
    guard let frame = currentVideoFrame else { return }
    await uploader.identify(image: frame)
  }

  // MARK: - Helpers

  private func handleVideoFrame(_ image: UIImage) {
    currentVideoFrame = image
    if !hasReceivedFirstFrame { hasReceivedFirstFrame = true }
    if detectionUploadsEnabled {
      Task { await uploader.submit(image: image) }
    }
  }

  private func handlePhoto(_ image: UIImage) {
    capturedPhoto = image
    capturedPhotoVersion += 1
  }

  private func handleStreamError(_ error: StreamError) {
    if streamingStatus == .stopped {
      if case .deviceNotConnected = error { return }
      if case .deviceNotFound = error { return }
    }
    show(formatStreamingError(error))
  }

  private func updateStatusFromState(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
      sessionManager.stop()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    @unknown default:
      streamingStatus = .waiting
    }
  }

  private func show(_ message: String) {
    errorMessage = message
    showError = true
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    error.localizedDescription
  }
}
