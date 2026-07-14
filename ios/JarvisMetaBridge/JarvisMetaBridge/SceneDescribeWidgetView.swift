//
// SceneDescribeWidgetView.swift
//
// Widget #2 in the Glasses Widgets app: "Scene Describe".
//
// Shows the live glasses view and, on demand, sends the current frame to JARVIS
// (Gemini vision) for a one-line caption. Unlike Identify Person, this widget does
// NOT stream frames for detection — it disables detection uploads on the shared
// stream session and only sends a single frame when you tap "Describe".
//

import MWDATCore
import SwiftUI
import UIKit

struct SceneDescribeWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var config: AppConfig
  @StateObject private var describer = SceneDescribeService()
  @StateObject private var speech = SpeechService()

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        preview
        controls
        captionCard
        historyCard
        errorCard
      }
      .padding()
    }
    .navigationTitle("Scene Describe")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await streamViewModel.refreshPermission()
    }
    // This widget captures on demand, so it doesn't need the per-second detection
    // stream — turn it off while here, restore it on exit for widget #1.
    .onAppear { streamViewModel.detectionUploadsEnabled = false }
    .onDisappear {
      streamViewModel.detectionUploadsEnabled = true
      speech.stop()
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
          Text(streamViewModel.isStreaming ? "Waiting for frame…" : "Start the stream to begin")
            .foregroundStyle(.secondary)
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
      }

      HStack(spacing: 12) {
        Button {
          Task { await streamViewModel.startStreaming() }
        } label: {
          Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(streamViewModel.isStreaming)

        Button {
          Task { await streamViewModel.stopStreaming() }
        } label: {
          Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!streamViewModel.isStreaming)
      }

      Button {
        Task {
          if let frame = streamViewModel.currentVideoFrame,
             let caption = await describer.describe(image: frame) {
            speech.speak(caption)
          }
        }
      } label: {
        Label(
          describer.isDescribing ? "Describing…" : "Describe what I see",
          systemImage: "text.viewfinder"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.green)
      .disabled(streamViewModel.currentVideoFrame == nil || describer.isDescribing)
    }
  }

  // MARK: - Caption

  private var captionCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Description", systemImage: "sparkles").fontWeight(.semibold)
        Spacer()
        if !describer.lastCaption.isEmpty {
          Button {
            if speech.isSpeaking { speech.stop() } else { speech.speak(describer.lastCaption) }
          } label: {
            Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
          }
        }
        Text(describer.status).font(.footnote).foregroundStyle(.secondary)
      }
      Text(describer.lastCaption.isEmpty ? "Tap “Describe what I see”." : describer.lastCaption)
        .font(.body)
        .foregroundStyle(describer.lastCaption.isEmpty ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - History

  @ViewBuilder
  private var historyCard: some View {
    if describer.history.count > 1 {
      VStack(alignment: .leading, spacing: 8) {
        Text("Recent").fontWeight(.semibold)
        ForEach(Array(describer.history.dropFirst().enumerated()), id: \.offset) { _, line in
          Text("• \(line)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: - Errors

  @ViewBuilder
  private var errorCard: some View {
    if let error = describer.lastError ?? (streamViewModel.showError ? streamViewModel.errorMessage : nil) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(error).font(.footnote)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(Color.orange.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }
}
