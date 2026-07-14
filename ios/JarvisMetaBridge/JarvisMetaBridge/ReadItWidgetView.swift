//
// ReadItWidgetView.swift
//
// Widget #3 in the Glasses Widgets app: "Read It".
//
// Captures one glasses frame and asks JARVIS to transcribe any visible text
// verbatim (OCR), then reads it aloud. This is the same backend endpoint as Scene
// Describe (/api/vision/describe) with a different prompt — demonstrating how new
// single-frame widgets are mostly a prompt swap.
//

import MWDATCore
import SwiftUI
import UIKit

struct ReadItWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var config: AppConfig
  @StateObject private var reader = SceneDescribeService()
  @StateObject private var speech = SpeechService()

  private static let ocrPrompt =
    "Transcribe all text visible in this image exactly as written, preserving "
    + "reading order and line breaks. Return only the text. If there is no legible "
    + "text, return exactly: No text detected."

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        preview
        controls
        textCard
        errorCard
      }
      .padding()
    }
    .navigationTitle("Read It")
    .navigationBarTitleDisplayMode(.inline)
    .task { await streamViewModel.refreshPermission() }
    .onAppear {
      streamViewModel.detectionUploadsEnabled = false
      reader.prompt = Self.ocrPrompt
    }
    .onDisappear {
      streamViewModel.detectionUploadsEnabled = true
      speech.stop()
    }
  }

  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
      if let frame = streamViewModel.currentVideoFrame {
        Image(uiImage: frame).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else {
        VStack(spacing: 8) {
          Image(systemName: "doc.text.viewfinder").font(.system(size: 40))
          Text(streamViewModel.isStreaming ? "Point at some text…" : "Start the stream to begin")
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      if !wearablesViewModel.isRegistered {
        Button { wearablesViewModel.connectGlasses() } label: {
          Label("Connect glasses (Meta AI)", systemImage: "link").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
      }

      HStack(spacing: 12) {
        Button { Task { await streamViewModel.startStreaming() } } label: {
          Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(streamViewModel.isStreaming)

        Button { Task { await streamViewModel.stopStreaming() } } label: {
          Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!streamViewModel.isStreaming)
      }

      Button {
        Task {
          guard let frame = streamViewModel.currentVideoFrame else { return }
          if let text = await reader.describe(image: frame) {
            speech.speak(text)
          }
        }
      } label: {
        Label(reader.isDescribing ? "Reading…" : "Read text", systemImage: "text.viewfinder")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.blue)
      .disabled(streamViewModel.currentVideoFrame == nil || reader.isDescribing)
    }
  }

  private var textCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Text", systemImage: "textformat").fontWeight(.semibold)
        Spacer()
        if !reader.lastCaption.isEmpty {
          Button {
            if speech.isSpeaking { speech.stop() } else { speech.speak(reader.lastCaption) }
          } label: {
            Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
          }
        }
      }
      Text(reader.lastCaption.isEmpty ? "Tap “Read text” to read what's in view." : reader.lastCaption)
        .font(reader.lastCaption.isEmpty ? .body : .body.monospaced())
        .foregroundStyle(reader.lastCaption.isEmpty ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var errorCard: some View {
    if let error = reader.lastError ?? (streamViewModel.showError ? streamViewModel.errorMessage : nil) {
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
