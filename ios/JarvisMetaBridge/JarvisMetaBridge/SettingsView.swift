//
// SettingsView.swift
//
// Lets you point the app at your JARVIS backend without recompiling.
// The value is persisted in UserDefaults (see AppConfig).
//

import SwiftUI

struct SettingsView: View {
  @ObservedObject var config: AppConfig
  @Environment(\.dismiss) private var dismiss
  @State private var draftURL: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("JARVIS backend URL") {
          TextField("http://192.168.1.100:8000", text: $draftURL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .font(.body.monospaced())
          if !draftIsValid {
            Label("Enter a valid http(s) URL", systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }

        Section {
          Button("Reset to default") {
            draftURL = AppConfig.defaultBackendURLString
          }
        } footer: {
          Text("Default: \(AppConfig.defaultBackendURLString). Run JARVIS with "
               + "`uvicorn main:app --reload --host 0.0.0.0 --port 8000` and use your Mac's LAN IP. "
               + "Every frame is sent with source \"\(AppConfig.frameSource)\" and target=false.")
        }
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            config.backendURLString = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
          }
          .disabled(!draftIsValid)
        }
      }
      .onAppear { draftURL = config.backendURLString }
    }
  }

  private var draftIsValid: Bool {
    let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host else {
      return false
    }
    return (scheme == "http" || scheme == "https") && !host.isEmpty
  }
}
