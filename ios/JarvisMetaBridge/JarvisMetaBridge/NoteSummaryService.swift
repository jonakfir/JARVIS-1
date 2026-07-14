//
// NoteSummaryService.swift
//
// Client for widget #4 (Note Buddy). Sends one document photo to JARVIS and gets
// back a structured study note. Reimplements the summarize step from
// Alphonso84/RayBan_Meta_NoteBuddy against our backend.
//
//   UIImage → JPEG (q≈0.80) → base64 → JSON → POST /api/vision/note
//
// Contract (verified against backend/schemas.py::NoteSummaryRequest/Response
// and backend/capture/note_summarizer.py).
//

import Foundation
import Combine
import UIKit

struct NoteSummaryResponse: Decodable {
  let title: String
  let summary: String
  let keyPoints: [String]
  let documentType: String
  let model: String
  let source: String
  let timestamp: Int?
  let success: Bool
  let error: String?

  enum CodingKeys: String, CodingKey {
    case title, summary
    case keyPoints = "key_points"
    case documentType = "document_type"
    case model, source, timestamp, success, error
  }
}

private struct NoteSummaryRequest: Encodable {
  let frame: String
  let source: String
  let timestamp: Int
}

@MainActor
final class NoteSummaryService: ObservableObject {
  @Published private(set) var lastNote: NoteSummaryResponse?
  @Published private(set) var status: String = "Idle"
  @Published private(set) var isSummarizing: Bool = false
  @Published private(set) var lastError: String?

  // Documents benefit from higher quality than the 0.70 used for detection frames.
  private let compressionQuality: CGFloat = 0.80
  private let config: AppConfig
  private let session: URLSession
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init(config: AppConfig? = nil) {
    self.config = config ?? .shared
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 45 // OCR + summarize can take a moment
    cfg.waitsForConnectivity = false
    self.session = URLSession(configuration: cfg)
  }

  /// Summarize one document image into a study note. Returns nil on failure/skip.
  @discardableResult
  func summarize(image: UIImage) async -> NoteSummaryResponse? {
    guard !isSummarizing else { return nil }

    guard let endpoint = config.endpoint("api/vision/note") else {
      updateError("Invalid backend URL: \(config.backendURLString)")
      return nil
    }
    guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else {
      updateError("Failed to JPEG-encode document")
      return nil
    }

    isSummarizing = true
    status = "Summarizing…"
    defer { isSummarizing = false }

    let payload = NoteSummaryRequest(
      frame: jpeg.base64EncodedString(),
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

      let decoded = try decoder.decode(NoteSummaryResponse.self, from: data)
      guard decoded.success else {
        updateError(decoded.error ?? "Empty note")
        return nil
      }
      lastNote = decoded
      lastError = nil
      status = "Summarized · \(decoded.model)"
      NSLog("[NoteSummaryService] OK title=%@ keyPoints=%d", decoded.title, decoded.keyPoints.count)
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
    status = "Error"
    NSLog("[NoteSummaryService] ERROR %@", message)
  }
}
