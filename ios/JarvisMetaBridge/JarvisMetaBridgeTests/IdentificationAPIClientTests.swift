import XCTest
@testable import JarvisMetaBridge

final class IdentificationAPIClientTests: XCTestCase {
  override func tearDown() {
    URLProtocolStub.handler = nil
    super.tearDown()
  }

  func testSubmitPostsExactlyOneTargetedGlassesFrame() async throws {
    let session = makeSession()
    var requests: [URLRequest] = []
    URLProtocolStub.handler = { request in
      requests.append(request)
      let body = #"{"capture_id":"cap","detections":[],"new_persons":0,"identifications":[{"request_id":"req-1","track_id":-1,"status":"identifying"}],"identification_admitted":true,"request_id":"req-1","timestamp":1,"source":"meta_glasses_ios"}"#.data(using: .utf8)!
      return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    let ticket = try await client.submit(jpegData: Data([0xFF, 0xD8, 0xFF]))

    XCTAssertEqual(ticket, IdentificationTicket(requestID: "req-1", trackID: -1))
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].httpMethod, "POST")
    XCTAssertEqual(requests[0].url?.path, "/api/capture/frame")
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try bodyData(for: requests[0])) as? [String: Any])
    XCTAssertEqual(json["target"] as? Bool, true)
    XCTAssertEqual(json["source"] as? String, "meta_glasses_ios")
    XCTAssertEqual(json["frame"] as? String, Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
  }

  func testStatusGetsEscapedRequestAndDecodesAllFields() async throws {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }, "/api/capture/identification/request%20one")
      let body = #"{"request_id":"request one","track_id":7,"status":"identified","name":"Jane Doe","linkedin_url":"https://www.linkedin.com/in/jane","job_title":"Engineer","company":"Acme","error":null}"#.data(using: .utf8)!
      return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    let result = try await client.status(requestID: "request one")

    XCTAssertEqual(result.status, .identified)
    XCTAssertEqual(result.name, "Jane Doe")
    XCTAssertEqual(result.jobTitle, "Engineer")
    XCTAssertEqual(result.company, "Acme")
  }

  func testHTTPFailureIsTyped() async {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("down".utf8))
    }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    await XCTAssertThrowsErrorAsync { _ = try await client.status(requestID: "r") } verify: {
      XCTAssertEqual($0 as? IdentificationAPIError, .httpStatus(503))
    }
  }

  func testMalformedResponseIsTyped() async {
    let session = makeSession()
    URLProtocolStub.handler = { request in
      (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
    }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    await XCTAssertThrowsErrorAsync { _ = try await client.status(requestID: "r") } verify: {
      guard case .decoding = $0 as? IdentificationAPIError else { return XCTFail("Expected decoding error") }
    }
  }

  func testIdentifyingAndFailedStatusesDecode() async throws {
    let session = makeSession()
    var status = "identifying"
    URLProtocolStub.handler = { request in
      let body = #"{"request_id":"r","track_id":-1,"status":"\#(status)","name":null,"linkedin_url":null,"job_title":null,"company":null,"error":"unavailable"}"#.data(using: .utf8)!
      return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    let identifying = try await client.status(requestID: "r")
    XCTAssertEqual(identifying.status, .identifying)
    status = "failed"
    let failed = try await client.status(requestID: "r")
    XCTAssertEqual(failed.status, .failed)
  }

  func testTimeoutIsTyped() async {
    let session = makeSession()
    URLProtocolStub.handler = { _ in throw URLError(.timedOut) }
    let client = IdentificationAPIClient(baseURL: URL(string: "http://jarvis.test:8000")!, session: session)

    await XCTAssertThrowsErrorAsync { _ = try await client.status(requestID: "r") } verify: {
      XCTAssertEqual($0 as? IdentificationAPIError, .timedOut)
    }
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    configuration.timeoutIntervalForRequest = 0.2
    return URLSession(configuration: configuration)
  }

  private func bodyData(for request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (response, data) = try Self.handler!(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

private extension XCTestCase {
  func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void = { _ in }
  ) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch { verify(error) }
  }
}
