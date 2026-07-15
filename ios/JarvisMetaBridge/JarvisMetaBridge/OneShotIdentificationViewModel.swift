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
  private var currentAttemptID: UUID?

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
    let attemptID = UUID()
    currentAttemptID = attemptID
    isBusy = true
    diagnosticMessage = nil
    attempt = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runAttempt(attemptID: attemptID)
      guard self.currentAttemptID == attemptID else { return }
      self.isBusy = false
      self.attempt = nil
      self.currentAttemptID = nil
    }
  }

  func confirmConsent() { startIdentification() }

  func cancel() {
    currentAttemptID = nil
    attempt?.cancel()
    attempt = nil
    cancelCapture()
    cancelDisplay()
    isBusy = false
    state = .idle
  }

  func disconnectGlasses(_ disconnect: @MainActor () -> Void) {
    cancel()
    disconnect()
  }

  private func runAttempt(attemptID: UUID) async {
    do {
      try await showCard(.identifying)
      try validate(attemptID)
      state = .capturing
      let jpeg = try await captureJPEG()
      try validate(attemptID)
      let ticket = try await submit(jpeg)
      try validate(attemptID)
      state = .identifying
      let expiresAt = now().addingTimeInterval(deadline)
      var displayedName: String?

      while now() < expiresAt {
        try validate(attemptID)
        let result = try await status(ticket.requestID)
        try validate(attemptID)
        switch result.status {
        case .failed:
          diagnosticMessage = result.error ?? "Identification failed"
          try await showCard(.notIdentified)
          try validate(attemptID)
          state = .notIdentified
          return
        case .identifying:
          break
        case .identified:
          guard let name = useful(result.name) else { break }
          if displayedName == nil {
            displayedName = name
            try await showCard(.name(name))
            try validate(attemptID)
            state = .nameDisplayed(name)
          }
          if let role = useful(result.jobTitle), let company = useful(result.company) {
            try await showCard(.enriched(name: name, role: role, company: company))
            try validate(attemptID)
            state = .enrichedCardDisplayed(name: name, role: role, company: company)
            return
          }
          state = .enriching(name)
        }
        try await sleep(.seconds(1))
        try validate(attemptID)
      }

      try validate(attemptID)
      if let displayedName { state = .nameDisplayed(displayedName) }
      else {
        diagnosticMessage = "Identification timed out"
        try await showCard(.notIdentified)
        try validate(attemptID)
        state = .notIdentified
      }
    } catch is CancellationError {
      return
    } catch {
      guard currentAttemptID == attemptID, !Task.isCancelled else { return }
      diagnosticMessage = error.localizedDescription
      do {
        try await showCard(.notIdentified)
        try validate(attemptID)
        state = .notIdentified
      } catch {
        guard currentAttemptID == attemptID, !Task.isCancelled else { return }
        state = .failed(diagnosticMessage ?? "Identification failed")
      }
    }
  }

  private func validate(_ attemptID: UUID) throws {
    try Task.checkCancellation()
    guard currentAttemptID == attemptID else { throw CancellationError() }
  }

  private func useful(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
