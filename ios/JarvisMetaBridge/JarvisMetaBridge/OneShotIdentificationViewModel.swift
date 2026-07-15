import Foundation

enum OneShotIdentificationUIState: Equatable {
  case idle
  case capturing
  case identifying
  case nameDisplayed(String)
  case enriching(String)
  case enrichedCardDisplayed(name: String, role: String, company: String)
  case notIdentified
  case failed(String)
}

@MainActor
final class OneShotIdentificationViewModel: ObservableObject {
  typealias Capture = @MainActor () async throws -> Data
  typealias Submit = @MainActor (Data) async throws -> IdentificationTicket
  typealias Status = @MainActor (String) async throws -> IdentificationResult
  typealias ShowCard = @MainActor (IdentityDisplayCard) async throws -> Void
  typealias Sleep = @MainActor (Duration) async throws -> Void

  @Published private(set) var state: OneShotIdentificationUIState = .idle
  @Published private(set) var diagnosticMessage: String?
  @Published private(set) var isBusy = false
  var isPrimaryActionEnabled: Bool { !isBusy }

  private let captureJPEG: Capture
  private let cancelCapture: @MainActor () -> Void
  private let submit: Submit
  private let status: Status
  private let showCard: ShowCard
  private let cancelDisplay: @MainActor () -> Void
  private let sleep: Sleep
  private let now: @MainActor () -> Date
  private let deadline: TimeInterval
  private var attempt: Task<Void, Never>?

  init(
    captureJPEG: @escaping Capture,
    cancelCapture: @escaping @MainActor () -> Void,
    submit: @escaping Submit,
    status: @escaping Status,
    showCard: @escaping ShowCard,
    cancelDisplay: @escaping @MainActor () -> Void,
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Date = Date.init,
    deadline: TimeInterval = 90
  ) {
    self.captureJPEG = captureJPEG
    self.cancelCapture = cancelCapture
    self.submit = submit
    self.status = status
    self.showCard = showCard
    self.cancelDisplay = cancelDisplay
    self.sleep = sleep
    self.now = now
    self.deadline = deadline
  }

  func startIdentification() {
    guard !isBusy else { return }
    isBusy = true
    diagnosticMessage = nil
    attempt = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runAttempt()
      if !Task.isCancelled { self.isBusy = false }
      self.attempt = nil
    }
  }

  func cancel() {
    attempt?.cancel()
    attempt = nil
    cancelCapture()
    cancelDisplay()
    isBusy = false
    state = .idle
  }

  private func runAttempt() async {
    do {
      try await showCard(.identifying)
      state = .capturing
      let jpeg = try await captureJPEG()
      try Task.checkCancellation()
      let ticket = try await submit(jpeg)
      state = .identifying
      let expiresAt = now().addingTimeInterval(deadline)
      var displayedName: String?

      while now() < expiresAt {
        try Task.checkCancellation()
        let result = try await status(ticket.requestID)
        switch result.status {
        case .failed:
          diagnosticMessage = result.error ?? "Identification failed"
          try await showCard(.notIdentified)
          state = .notIdentified
          return
        case .identifying:
          break
        case .identified:
          guard let name = useful(result.name) else { break }
          if displayedName == nil {
            displayedName = name
            try await showCard(.name(name))
            state = .nameDisplayed(name)
          }
          if let role = useful(result.jobTitle), let company = useful(result.company) {
            try await showCard(.enriched(name: name, role: role, company: company))
            state = .enrichedCardDisplayed(name: name, role: role, company: company)
            return
          }
          state = .enriching(name)
        }
        try await sleep(.seconds(1))
      }

      if let displayedName { state = .nameDisplayed(displayedName) }
      else {
        diagnosticMessage = "Identification timed out"
        try await showCard(.notIdentified)
        state = .notIdentified
      }
    } catch is CancellationError {
      return
    } catch {
      diagnosticMessage = error.localizedDescription
      do {
        try await showCard(.notIdentified)
        state = .notIdentified
      } catch {
        state = .failed(diagnosticMessage ?? "Identification failed")
      }
    }
  }

  private func useful(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
