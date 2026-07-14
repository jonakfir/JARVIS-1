//
// SceneDescribeService.swift
//
// Client for widget #2 (Scene Describe). Captures ONE glasses frame on demand and
// asks JARVIS to caption it via Gemini vision.
//
//   UIImage → JPEG (q≈0.70) → base64 → JSON → POST /api/vision/describe
//
// Contract (verified against backend/schemas.py::SceneDescribeRequest/Response
// and backend/capture/scene_describer.py):
//
//   Request : { "frame": <base64 JPEG>, "prompt": <string>,
//               "source": <string>, "timestamp": <int ms | null> }
//   Response: { "caption": string, "model": string, "source": string,
//               "timestamp": int?, "success": bool, "error": string? }
//
// This is a describe-only path: it never runs face identification.
//

import Foundation
import Combine
import UIKit

struct SceneDescribeResponse: Decodable {
  let caption: String
  let model: String
  let source: String
  let timestamp: Int?
  let success: Bool
  let error: String?
}

private struct SceneDescribeRequest: Encodable {
  let frame: String
  let prompt: String
  let source: String
  let timestamp: Int
}

@MainActor
final class SceneDescribeService: ObservableObject {
  /// Latest caption returned by JARVIS.
  @Published private(set) var lastCaption: String = ""
  /// Human-readable status for the UI.
  @Published private(set) var status: String = "Idle"
  /// True while a describe request is in flight (prevents overlap).
  @Published private(set) var isDescribing: Bool = false
  /// Most recent error, or nil after a success.
  @Published private(set) var lastError: String?
  /// Rolling history of captions, newest first (handy as a "visual memory" log).
  @Published private(set) var history: [String] = []

  /// The default prompt. Swap this to repurpose the same endpoint for other
  /// single-frame widgets (e.g. "Read all text aloud", "Translate any text to English").
  var prompt = "Describe what is in front of me in one clear, concise sentence."

  private let compressionQuality: CGFloat = 0.70
  private let config: AppConfig
  private let session: URLSession
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init(config: AppConfig? = nil) {
    self.config = config ?? .shared
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30 // vision calls are slower than detection
    cfg.waitsForConnectivity = false
    self.session = URLSession(configuration: cfg)
  }

  /// Send one frame for captioning. Returns the caption, or nil on failure/skip.
  @discardableResult
  func describe(image: UIImage) async -> String? {
    guard !isDescribing else { return nil }

    guard let endpoint = config.describeEndpointURL else {
      updateError("Invalid backend URL: \(config.backendURLString)")
      return nil
    }
    guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else {
      updateError("Failed to JPEG-encode frame")
      return nil
    }

    isDescribing = true
    status = "Describing…"
    defer { isDescribing = false }

    let payload = SceneDescribeRequest(
      frame: jpeg.base64EncodedString(),
      prompt: prompt,
      source: AppConfig.frameSource,
      timestamp: Int(Date().timeIntervalSince1970 * 1000)
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

      let decoded = try decoder.decode(SceneDescribeResponse.self, from: data)
      guard decoded.success, !decoded.caption.isEmpty else {
        updateError(decoded.error ?? "Empty caption")
        return nil
      }

      lastCaption = decoded.caption
      history.insert(decoded.caption, at: 0)
      if history.count > 10 { history.removeLast(history.count - 10) }
      lastError = nil
      status = "Described · \(decoded.model)"
      NSLog("[SceneDescribeService] OK caption=%@", decoded.caption)
      return decoded.caption
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
    status = "Error"
    NSLog("[SceneDescribeService] ERROR %@", message)
  }
}
