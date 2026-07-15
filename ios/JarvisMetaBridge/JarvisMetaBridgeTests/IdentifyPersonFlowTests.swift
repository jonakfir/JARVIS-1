import XCTest
@testable import JarvisMetaBridge

@MainActor
final class IdentifyPersonFlowTests: XCTestCase {
  func testPrimaryActionIsAvailableOnlyWhenIdleAndDismissCancels() async {
    var captureCancelled = 0
    var displayCancelled = 0
    let model = OneShotIdentificationViewModel(
      captureJPEG: {
        while true { try await Task.sleep(for: .seconds(1)) }
      },
      cancelCapture: { captureCancelled += 1 },
      submit: { _ in IdentificationTicket(requestID: "r", trackID: -1) },
      status: { _ in .init(requestID: "r", trackID: -1, status: .identifying,
        name: nil, linkedinURL: nil, jobTitle: nil, company: nil, error: nil) },
      showCard: { _ in },
      cancelDisplay: { displayCancelled += 1 })

    XCTAssertTrue(model.isPrimaryActionEnabled)
    model.startIdentification()
    XCTAssertFalse(model.isPrimaryActionEnabled)
    model.cancel()
    XCTAssertTrue(model.isPrimaryActionEnabled)
    XCTAssertEqual(captureCancelled, 1)
    XCTAssertEqual(displayCancelled, 1)
  }
}
