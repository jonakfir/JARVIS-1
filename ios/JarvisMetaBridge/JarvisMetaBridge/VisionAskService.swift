//
// VisionAskService.swift
//
// Client for the "Voice Guide" widget: sends one glasses frame + a question to
// JARVIS, which answers via Claude (default) or Gemini and returns text.
//
//   UIImage → JPEG (q≈0.70) → base64 + question → POST /api/vision/ask
//
// Contract: backend/schemas.py::VisionAskRequest/Response, backend/capture/vision_ask.py.
// The model API key stays server-side (per repo policy) — this only sends the frame.
//

import Foundation
import Combine
import UIKit

struct VisionAskResponse: Decodable {
  let answer: String
  let model: String
  let source: String
  let timestamp: Int?
  let success: Bool
  let error: String?
}

private struct VisionAskRequest: Encodable {
  let frame: String
  let question: String
  let model: String
  let source: String
  let timestamp: Int
}

@MainActor
final class VisionAskService: ObservableObject {
  @Published private(set) var lastAnswer: String = ""
  @Published private(set) var lastModel: String = ""
  @Published private(set) var status: String = "Idle"
  @Published private(set) var isAsking: Bool = false
  @Published private(set) var lastError: String?

  /// Which backend model to prefer: "claude" (default) or "gemini".
  var model = "claude"

  private let compressionQuality: CGFloat = 0.70
  private let config: AppConfig
  private let session: URLSession
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init(config: AppConfig? = nil) {
    self.config = config ?? .shared
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 45
    cfg.waitsForConnectivity = false
    self.session = URLSession(configuration: cfg)
  }

  @discardableResult
  func ask(image: UIImage, question: String) async -> String? {
    guard !isAsking else { return nil }
    let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQ.isEmpty else {
      updateError("No question captured")
      return nil
    }
    guard let endpoint = config.endpoint("api/vision/ask") else {
      updateError("Invalid backend URL: \(config.backendURLString)")
      return nil
    }
    guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else {
      updateError("Failed to JPEG-encode frame")
      return nil
    }

    isAsking = true
    status = "Asking \(model)…"
    defer { isAsking = false }

    let payload = VisionAskRequest(
      frame: jpeg.base64EncodedString(),
      question: trimmedQ,
      model: model,
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
      let decoded = try decoder.decode(VisionAskResponse.self, from: data)
      guard decoded.success, !decoded.answer.isEmpty else {
        updateError(decoded.error ?? "Empty answer")
        return nil
      }
      lastAnswer = decoded.answer
      lastModel = decoded.model
      lastError = nil
      status = "Answered · \(decoded.model)"
      NSLog("[VisionAskService] OK model=%@ answer=%@", decoded.model, decoded.answer)
      return decoded.answer
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
    NSLog("[VisionAskService] ERROR %@", message)
  }
}
