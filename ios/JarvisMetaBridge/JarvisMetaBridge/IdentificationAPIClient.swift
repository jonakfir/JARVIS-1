import Foundation

struct IdentificationTicket: Codable, Sendable, Equatable {
  let requestID: String
  let trackID: Int

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case trackID = "track_id"
  }
}

enum IdentificationState: String, Codable, Sendable {
  case identifying
  case identified
  case failed
}

struct IdentificationResult: Codable, Sendable, Equatable {
  let requestID: String
  let trackID: Int
  let status: IdentificationState
  let name: String?
  let linkedinURL: URL?
  let jobTitle: String?
  let company: String?
  let error: String?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case trackID = "track_id"
    case status, name
    case linkedinURL = "linkedin_url"
    case jobTitle = "job_title"
    case company, error
  }
}

enum IdentificationAPIError: Error, Sendable, Equatable {
  case invalidEndpoint
  case invalidAdmission
  case httpStatus(Int)
  case timedOut
  case transport(String)
  case decoding
}

struct IdentificationAPIClient: Sendable {
  private struct Submission: Encodable {
    let frame: String
    let timestamp: Int
    let source = AppConfig.frameSource
    let target = true
  }

  private struct Admission: Decodable {
    let identifications: [IdentificationTicket]
    let identificationAdmitted: Bool
    let requestID: String?

    enum CodingKeys: String, CodingKey {
      case identifications
      case identificationAdmitted = "identification_admitted"
      case requestID = "request_id"
    }
  }

  private let baseURL: URL
  private let session: URLSession
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  @MainActor
  init(config: AppConfig = .shared, session: URLSession = .shared) throws {
    guard let url = URL(string: config.backendURLString) else {
      throw IdentificationAPIError.invalidEndpoint
    }
    self.init(baseURL: url, session: session)
  }

  func submit(jpegData: Data) async throws -> IdentificationTicket {
    var request = URLRequest(url: endpoint("api/capture/frame"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(Submission(
      frame: jpegData.base64EncodedString(),
      timestamp: Int(Date().timeIntervalSince1970 * 1_000)))
    let admission: Admission = try await send(request)
    guard admission.identificationAdmitted,
          let requestID = admission.requestID,
          let ticket = admission.identifications.last(where: { $0.requestID == requestID })
    else { throw IdentificationAPIError.invalidAdmission }
    return ticket
  }

  func status(requestID: String) async throws -> IdentificationResult {
    var request = URLRequest(url: endpoint("api/capture/identification/\(requestID)"))
    request.httpMethod = "GET"
    return try await send(request)
  }

  private func endpoint(_ path: String) -> URL {
    path.split(separator: "/").reduce(baseURL) { url, component in
      url.appendingPathComponent(String(component))
    }
  }

  private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw IdentificationAPIError.transport("Missing HTTP response")
      }
      guard (200...299).contains(http.statusCode) else {
        throw IdentificationAPIError.httpStatus(http.statusCode)
      }
      do { return try decoder.decode(Response.self, from: data) }
      catch { throw IdentificationAPIError.decoding }
    } catch let error as IdentificationAPIError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw IdentificationAPIError.timedOut
    } catch {
      throw IdentificationAPIError.transport(error.localizedDescription)
    }
  }
}
