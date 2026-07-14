//
// StreamSessionViewModel.swift
//
// Drives the glasses camera video stream via the DAT SDK (`MWDATCamera`) and
// forwards each frame to JARVIS through `JarvisFrameUploader`.
//
// Adapted from Meta's official CameraAccess sample — uses only real SDK APIs
// (SDK 0.4.0): StreamSession, StreamSessionConfig, AutoDeviceSelector,
// VideoCodec.raw, StreamingResolution, StreamSessionState, StreamSessionError,
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
  private var streamSession: StreamSession
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?

  init(wearables: WearablesInterface, uploader: JarvisFrameUploader) {
    self.wearables = wearables
    self.uploader = uploader
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24)
    self.streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    deviceMonitorTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    attachListeners()
  }

  deinit {
    deviceMonitorTask?.cancel()
  }

  private func attachListeners() {
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let image = videoFrame.makeUIImage() else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
        // Forward to JARVIS for detection only when enabled. The uploader
        // self-throttles to ~1 fps and drops frames while a prior upload is in
        // flight, so calling per-frame is safe.
        if self.detectionUploadsEnabled {
          Task { await self.uploader.submit(image: image) }
        }
      }
    }

    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress "no device" noise before the user starts streaming.
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        self.show(self.formatStreamingError(error))
      }
    }

    // High-resolution still capture (Note Buddy).
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let image = UIImage(data: photoData.data) {
          self.capturedPhoto = image
          self.capturedPhotoVersion += 1
        }
      }
    }

    updateStatusFromState(streamSession.state)
  }

  /// Trigger a high-resolution photo. Result arrives on `capturedPhoto`.
  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
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
      await streamSession.start()
    } catch {
      show("Permission error: \(error.localizedDescription)")
    }
  }

  func stopStreaming() async {
    await streamSession.stop()
  }

  /// Send the CURRENT frame for a one-shot, consent-gated identification.
  /// Call only from a deliberate user action after the subject has consented.
  func identifyCurrentFrame() async {
    guard let frame = currentVideoFrame else { return }
    await uploader.identify(image: frame)
  }

  // MARK: - Helpers

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      streamingStatus = .stopped
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

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError: return "An internal error occurred. Please try again."
    case .deviceNotFound: return "Device not found. Ensure your glasses are connected."
    case .deviceNotConnected: return "Device not connected. Check your connection and retry."
    case .timeout: return "The operation timed out. Please try again."
    case .videoStreamingError: return "Video streaming failed. Please try again."
    case .audioStreamingError: return "Audio streaming failed. Please try again."
    case .permissionDenied: return "Camera permission denied. Grant it in Settings."
    case .hingesClosed: return "The glasses hinges are closed. Open them and try again."
    @unknown default: return "An unknown streaming error occurred."
    }
  }
}
