//
// JarvisFrameUploader.swift
//
// Reusable uploader that pushes glasses frames to the JARVIS backend.
//
//   UIImage → JPEG (q≈0.70) → base64 → JSON → POST /api/capture/frame
//
// Contract (verified against backend/schemas.py + backend/capture/frame_handler.py):
//
//   Request body  (FrameSubmission):
//     { "frame": <base64 JPEG string>, "timestamp": <int, ms since epoch>,
//       "source": <string>, "target": <bool> }
//
//   Response body (FrameProcessedResponse):
//     { "capture_id": string,
//       "detections": [ { "bbox": [float], "confidence": float, "track_id": int? } ],
//       "new_persons": int,
//       "identifications": [ { "track_id": int, "status": string,
//                              "name": string?, "person_id": string? } ],
//       "timestamp": int, "source": string }
//
// SAFETY / PRIVACY: the streaming path (`submit`) ALWAYS sends `target: false`
// (person detection only). `target: true` — which asks the backend to run face
// identification / reverse search — is sent ONLY by `identify(image:)`: a
// deliberate, one-shot, user-initiated action, taken per subject and only with
// that person's consent. It is never sent automatically, on a timer, or from the
// streaming loop.
//

import Foundation
import Combine
import UIKit

// MARK: - Wire models

/// Mirrors backend `FrameProcessedResponse`.
struct FrameProcessedResponse: Decodable {
  struct Detection: Decodable {
    let bbox: [Double]
    let confidence: Double
    let trackId: Int?

    enum CodingKeys: String, CodingKey {
      case bbox
      case confidence
      case trackId = "track_id"
    }
  }

  struct Identification: Decodable {
    let trackId: Int
    let status: String
    let name: String?
    let personId: String?

    enum CodingKeys: String, CodingKey {
      case trackId = "track_id"
      case status
      case name
      case personId = "person_id"
    }
  }

  let captureId: String
  let detections: [Detection]
  let newPersons: Int
  let identifications: [Identification]
  let timestamp: Int
  let source: String

  enum CodingKeys: String, CodingKey {
    case captureId = "capture_id"
    case detections
    case newPersons = "new_persons"
    case identifications
    case timestamp
    case source
  }
}

/// Mirrors backend `FrameSubmission`. `target` is false for streaming; true only
/// for an explicit, consent-gated `identify()` call.
private struct FrameSubmission: Encodable {
  let frame: String
  let timestamp: Int
  let source: String
  let target: Bool
}

// MARK: - Uploader

@MainActor
final class JarvisFrameUploader: ObservableObject {
  /// Human-readable status of the most recent upload attempt (for the UI).
  @Published private(set) var lastStatus: String = "Idle"
  /// Number of detections returned by JARVIS on the last successful upload.
  @Published private(set) var lastDetectionCount: Int = 0
  /// Total frames successfully accepted by the backend this session.
  @Published private(set) var uploadedCount: Int = 0
  /// Most recent error message, or nil when the last attempt succeeded.
  @Published private(set) var lastError: String?
  /// The full most-recent response (handy for showing names/identifications).
  @Published private(set) var lastResponse: FrameProcessedResponse?
  /// Status of the most recent explicit, consent-gated identification request.
  @Published private(set) var identifyStatus: String = "Idle"
  /// True while a one-shot identification request is in flight.
  @Published private(set) var isIdentifying: Bool = false

  /// JPEG compression quality. ~0.70 keeps frames small enough for ~1 fps upload.
  private let compressionQuality: CGFloat = 0.70
  /// Minimum spacing between uploads: at most one frame per second.
  private let minInterval: TimeInterval = 1.0

  private let config: AppConfig
  private let session: URLSession
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  /// Guards against overlapping uploads — a frame is dropped while one is in flight.
  private var isUploading = false
  private var lastUploadStartedAt: Date = .distantPast

  init(config: AppConfig? = nil) {
    self.config = config ?? .shared
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 15
    sessionConfig.waitsForConnectivity = false
    self.session = URLSession(configuration: sessionConfig)
    self.decoder = JSONDecoder()
    self.encoder = JSONEncoder()
  }

  /// Stream a frame for DETECTION ONLY (target = false).
  ///
  /// Safe to call at the camera frame rate — self-throttles to ~1 fps and drops
  /// frames while a prior upload is still running. This never asks the backend to
  /// identify anyone. Returns the decoded response, or nil if skipped/failed.
  @discardableResult
  func submit(image: UIImage) async -> FrameProcessedResponse? {
    let now = Date()
    guard now.timeIntervalSince(lastUploadStartedAt) >= minInterval else { return nil }
    guard !isUploading else { return nil }
    isUploading = true
    lastUploadStartedAt = now
    lastStatus = "Uploading…"
    defer { isUploading = false }
    return await perform(image: image, target: false)
  }

  /// One-shot, user-initiated identification request (target = true).
  ///
  /// This is the ONLY path that sends `target: true`. Call it only from a
  /// deliberate user action, once per subject, and only after the subject has
  /// consented — never on a timer and never from the streaming loop. The backend
  /// serializes face searches internally, so at most one runs at a time; the
  /// resolved name then arrives on the ongoing detection stream as an
  /// `identifications` entry.
  @discardableResult
  func identify(image: UIImage) async -> FrameProcessedResponse? {
    guard !isIdentifying else { return nil }
    isIdentifying = true
    identifyStatus = "Requesting identification…"
    defer { isIdentifying = false }
    return await perform(image: image, target: true)
  }

  /// Shared encode → POST → decode. `target` is supplied by the caller: false for
  /// the streaming path, true only for the explicit `identify(image:)` action.
  private func perform(image: UIImage, target: Bool) async -> FrameProcessedResponse? {
    guard let endpoint = config.frameEndpointURL else {
      updateError("Invalid backend URL: \(config.backendURLString)")
      return nil
    }
    guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else {
      updateError("Failed to JPEG-encode frame")
      return nil
    }

    let payload = FrameSubmission(
      frame: jpeg.base64EncodedString(),
      timestamp: Int(Date().timeIntervalSince1970 * 1000),
      source: AppConfig.frameSource,
      target: target
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      request.httpBody = try encoder.encode(payload)
    } catch {
      updateError("Failed to encode request: \(error.localizedDescription)")
      return nil
    }

    do {
      let (data, urlResponse) = try await session.data(for: request)
      guard let http = urlResponse as? HTTPURLResponse else {
        updateError("No HTTP response from \(endpoint.absoluteString)")
        return nil
      }
      guard (200...299).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        updateError("HTTP \(http.statusCode) from JARVIS: \(body.prefix(200))")
        return nil
      }

      let decoded = try decoder.decode(FrameProcessedResponse.self, from: data)
      lastResponse = decoded
      lastDetectionCount = decoded.detections.count
      lastError = nil
      if target {
        identifyStatus = "Identification requested · \(decoded.detections.count) person(s) in frame"
      } else {
        uploadedCount += 1
        lastStatus = "OK · \(decoded.detections.count) detection(s) · capture \(decoded.captureId)"
      }
      NSLog(
        "[JarvisFrameUploader] OK target=%@ capture=%@ detections=%d identifications=%d",
        target ? "true" : "false", decoded.captureId,
        decoded.detections.count, decoded.identifications.count
      )
      return decoded
    } catch let urlError as URLError {
      updateError("Network error: \(urlError.localizedDescription) (\(endpoint.absoluteString))")
      return nil
    } catch {
      updateError("Decode/other error: \(error.localizedDescription)")
      return nil
    }
  }

  private func updateError(_ message: String) {
    lastError = message
    lastStatus = "Error"
    NSLog("[JarvisFrameUploader] ERROR %@", message)
  }
}
