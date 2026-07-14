//
// IdentifyPersonWidgetView.swift
//
// Widget #1 in the Glasses Widgets app: "Identify Person".
//
// Streams the glasses camera to JARVIS for on-device person detection, and offers
// a deliberate, consent-gated one-shot "Identify person" action (the only path
// that sends target: true). See JarvisFrameUploader for the safety model.
//

import MWDATCore
import SwiftUI
import UIKit

struct IdentifyPersonWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var config: AppConfig

  @State private var showSettings = false
  @State private var showIdentifyConsent = false

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        statusCard
        preview
        controls
        uploadCard
        errorsCard
      }
      .padding()
    }
    .navigationTitle("Identify Person")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showSettings = true
        } label: {
          Image(systemName: "gearshape")
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      SettingsView(config: config)
    }
    .confirmationDialog(
      "Identify the person in view?",
      isPresented: $showIdentifyConsent,
      titleVisibility: .visible
    ) {
      Button("They consented — identify") {
        Task { await streamViewModel.identifyCurrentFrame() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Only with the person's clear, in-the-moment consent. This sends one "
           + "frame to JARVIS to look up who they are.")
    }
    .task {
      await streamViewModel.refreshPermission()
    }
  }

  // MARK: - Status

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      statusRow(
        title: "Meta AI",
        value: wearablesViewModel.registrationLabel,
        ok: wearablesViewModel.isRegistered)
      statusRow(
        title: "Glasses",
        value: wearablesViewModel.deviceSummary,
        ok: streamViewModel.hasActiveDevice)
      statusRow(
        title: "Camera permission",
        value: streamViewModel.cameraPermissionGranted ? "Granted" : "Not granted",
        ok: streamViewModel.cameraPermissionGranted)
      statusRow(
        title: "Stream",
        value: streamStatusText,
        ok: streamViewModel.streamingStatus == .streaming)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func statusRow(title: String, value: String, ok: Bool) -> some View {
    HStack(alignment: .top) {
      Circle()
        .fill(ok ? Color.green : Color.gray)
        .frame(width: 10, height: 10)
        .padding(.top, 5)
      Text(title).fontWeight(.semibold)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  private var streamStatusText: String {
    switch streamViewModel.streamingStatus {
    case .streaming: return "Streaming"
    case .waiting: return "Waiting…"
    case .stopped: return "Stopped"
    }
  }

  // MARK: - Preview

  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
      if let frame = streamViewModel.currentVideoFrame {
        Image(uiImage: frame)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else {
        VStack(spacing: 8) {
          Image(systemName: "eyeglasses").font(.system(size: 40))
          Text("No frame yet").foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Controls

  private var controls: some View {
    VStack(spacing: 12) {
      if !wearablesViewModel.isRegistered {
        Button {
          wearablesViewModel.connectGlasses()
        } label: {
          Label("Connect glasses (Meta AI)", systemImage: "link")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button(role: .destructive) {
          wearablesViewModel.disconnectGlasses()
        } label: {
          Label("Disconnect", systemImage: "link.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }

      HStack(spacing: 12) {
        Button {
          Task { await streamViewModel.startStreaming() }
        } label: {
          Label("Start Stream", systemImage: "play.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(streamViewModel.isStreaming)

        Button {
          Task { await streamViewModel.stopStreaming() }
        } label: {
          Label("Stop Stream", systemImage: "stop.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!streamViewModel.isStreaming)
      }

      // Consent-gated, one-shot identification. Only shown while streaming.
      if streamViewModel.isStreaming {
        Button {
          showIdentifyConsent = true
        } label: {
          Label("Identify person (with consent)", systemImage: "person.fill.viewfinder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.purple)
        .disabled(streamViewModel.currentVideoFrame == nil || streamViewModel.uploader.isIdentifying)
      }
    }
  }

  // MARK: - Upload status

  private var uploadCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("JARVIS backend").fontWeight(.semibold)
        Spacer()
        Button("Change") { showSettings = true }.font(.footnote)
      }
      Text(config.backendURLString)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Divider()

      LabeledContent("Upload status", value: streamViewModel.uploader.lastStatus)
      LabeledContent("Latest detections", value: "\(streamViewModel.uploader.lastDetectionCount)")
      LabeledContent("Frames accepted", value: "\(streamViewModel.uploader.uploadedCount)")

      Divider()

      LabeledContent("Identify status", value: streamViewModel.uploader.identifyStatus)
      if let idents = streamViewModel.uploader.lastResponse?.identifications, !idents.isEmpty {
        ForEach(idents, id: \.trackId) { ident in
          LabeledContent("Person #\(ident.trackId)", value: identLabel(ident))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func identLabel(_ ident: FrameProcessedResponse.Identification) -> String {
    if ident.status == "failed", let error = ident.error, !error.isEmpty {
      return "failed · \(error)"
    }
    if let name = ident.name, !name.isEmpty { return "\(ident.status) · \(name)" }
    return ident.status
  }

  // MARK: - Errors

  @ViewBuilder
  private var errorsCard: some View {
    let uploadError = streamViewModel.uploader.lastError
    let streamError = streamViewModel.showError ? streamViewModel.errorMessage : nil
    let wearableError = wearablesViewModel.showError ? wearablesViewModel.errorMessage : nil

    if uploadError != nil || streamError != nil || wearableError != nil {
      VStack(alignment: .leading, spacing: 8) {
        Label("Errors", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fontWeight(.semibold)
        if let wearableError { errorLine(wearableError) }
        if let streamError { errorLine(streamError) }
        if let uploadError { errorLine(uploadError) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(Color.orange.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  private func errorLine(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
