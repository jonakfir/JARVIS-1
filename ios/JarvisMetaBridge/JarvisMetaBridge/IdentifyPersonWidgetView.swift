import SwiftUI

struct IdentifyPersonWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var identificationViewModel: OneShotIdentificationViewModel
  @ObservedObject var config: AppConfig
  @State private var showSettings = false
  @State private var showConsent = false

  var body: some View {
    ScrollView {
      VStack(spacing: 16) { statusCard; controls; backendCard; errorsCard }.padding()
    }
    .navigationTitle("Identify Person").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .topBarTrailing) {
      Button { showSettings = true } label: { Image(systemName: "gearshape") }
    }}
    .sheet(isPresented: $showSettings) { SettingsView(config: config) }
    .confirmationDialog("Identify the person in view?", isPresented: $showConsent,
      titleVisibility: .visible) {
      Button("They consented — identify") { identificationViewModel.confirmConsent() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Only with the person's clear, in-the-moment consent. This captures and sends one photo to JARVIS.")
    }
    .task { await streamViewModel.refreshPermission() }
    .onDisappear { identificationViewModel.cancel() }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      row("Meta AI", wearablesViewModel.registrationLabel, wearablesViewModel.isRegistered)
      row("Glasses", wearablesViewModel.deviceSummary, wearablesViewModel.isRegistered)
      row("Camera permission", streamViewModel.cameraPermissionGranted ? "Granted" : "Not granted",
        streamViewModel.cameraPermissionGranted)
      row("Identify", stateLabel, identificationViewModel.isBusy)
    }.cardStyle()
  }

  private func row(_ title: String, _ value: String, _ ok: Bool) -> some View {
    HStack(alignment: .top) {
      Circle().fill(ok ? Color.green : Color.gray).frame(width: 10, height: 10).padding(.top, 5)
      Text(title).fontWeight(.semibold); Spacer()
      Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      if !streamViewModel.cameraPermissionGranted {
        Button {
          Task { await streamViewModel.requestCameraPermission() }
        } label: {
          Label("Grant camera access", systemImage: "camera.fill")
            .frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)
      }

      if !wearablesViewModel.isRegistered {
        Button { wearablesViewModel.connectGlasses() } label: {
          Label("Connect glasses (Meta AI)", systemImage: "link").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)
      } else {
        Button { wearablesViewModel.updateGlassesApp() } label: {
          Label("Update glasses app", systemImage: "arrow.triangle.2.circlepath")
            .frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)

        Button(role: .destructive) {
          identificationViewModel.disconnectGlasses { wearablesViewModel.disconnectGlasses() }
        } label: {
          Label("Disconnect", systemImage: "link.badge.plus").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered)
      }
      Button { showConsent = true } label: {
        Label(identificationViewModel.isBusy ? "Identifying…" : "Identify Person",
          systemImage: "person.fill.viewfinder").frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).tint(.purple)
        .disabled(!identificationViewModel.isPrimaryActionEnabled || !wearablesViewModel.isRegistered)
    }
  }

  private var backendCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack { Text("JARVIS backend").fontWeight(.semibold); Spacer()
        Button("Change") { showSettings = true }.font(.footnote) }
      Text(config.backendURLString).font(.footnote.monospaced()).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
      Divider(); LabeledContent("Status", value: stateLabel)
      if let diagnostic = identificationViewModel.diagnosticMessage {
        Text(diagnostic).font(.footnote).foregroundStyle(.secondary)
      }
    }.cardStyle()
  }

  @ViewBuilder private var errorsCard: some View {
    let streamError = streamViewModel.showError ? streamViewModel.errorMessage : nil
    let wearableError = wearablesViewModel.showError ? wearablesViewModel.errorMessage : nil
    if streamError != nil || wearableError != nil {
      VStack(alignment: .leading, spacing: 8) {
        Label("Errors", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).fontWeight(.semibold)
        if let wearableError { Text(wearableError).font(.footnote) }
        if let streamError { Text(streamError).font(.footnote) }
      }.cardStyle().background(Color.orange.opacity(0.12))
    }
  }

  private var stateLabel: String {
    switch identificationViewModel.state {
    case .idle: return "Ready"
    case .capturing: return "Capturing one photo…"
    case .identifying: return "Identifying…"
    case .nameDisplayed(let name): return name
    case .enriching(let name): return "\(name) · checking role…"
    case .enrichedCardDisplayed(let name, let role, let company): return "\(name) — \(role) at \(company)"
    case .notIdentified: return "Not identified"
    case .failed(let message): return message
    }
  }
}

private extension View {
  func cardStyle() -> some View {
    frame(maxWidth: .infinity, alignment: .leading).padding()
      .background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
  }
}
