//
// VoiceGuideWidgetView.swift
//
// Widget #5: "Voice Guide" — hands-free, agentic scene interpretation with model
// freedom (OpenGlasses-style). Speak a question, and JARVIS answers about what the
// glasses see using Claude (default) or Gemini, then reads the answer aloud.
//
// Flow: hold to talk (Apple Speech STT, glasses BT mic) → on release, capture the
// current glasses frame + your transcript → POST /api/vision/ask → speak the answer.
//

import MWDATCore
import SwiftUI
import UIKit

struct VoiceGuideWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var config: AppConfig
  @StateObject private var voice = VoiceInputService()
  @StateObject private var asker = VisionAskService()
  @StateObject private var speech = SpeechService()

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        preview
        modelPicker
        controls
        transcriptCard
        answerCard
        errorCard
      }
      .padding()
    }
    .navigationTitle("Voice Guide")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await streamViewModel.refreshPermission()
      await voice.requestAuthorization()
    }
    .onAppear { streamViewModel.detectionUploadsEnabled = false }
    .onDisappear {
      streamViewModel.detectionUploadsEnabled = true
      voice.stop()
      speech.stop()
    }
  }

  // MARK: - Preview

  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(Color.black)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
      if let frame = streamViewModel.currentVideoFrame {
        Image(uiImage: frame).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else {
        VStack(spacing: 8) {
          Image(systemName: "waveform.and.person.filled").font(.system(size: 40))
          Text(streamViewModel.isStreaming ? "Ask about what you see" : "Start the stream to begin")
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Model freedom

  private var modelPicker: some View {
    Picker("Model", selection: $asker.model) {
      Text("Claude").tag("claude")
      Text("Gemini").tag("gemini")
    }
    .pickerStyle(.segmented)
  }

  // MARK: - Controls

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
        .buttonStyle(.bordered).disabled(streamViewModel.isStreaming)

        Button { Task { await streamViewModel.stopStreaming() } } label: {
          Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).disabled(!streamViewModel.isStreaming)
      }

      // Hold to talk: press to listen, release to ask.
      Button {
        // No-op; handled by the long-press gesture below.
      } label: {
        Label(
          voice.isListening ? "Listening… release to ask"
            : (asker.isAsking ? "Thinking…" : "Hold to talk"),
          systemImage: voice.isListening ? "waveform" : "mic.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(voice.isListening ? .red : .indigo)
      .disabled(!streamViewModel.isStreaming || !voice.authorized || asker.isAsking)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !voice.isListening && !asker.isAsking { voice.start() }
          }
          .onEnded { _ in
            if voice.isListening { voice.stop() }
            askAboutFrame()
          }
      )

      if !voice.authorized {
        Text("Grant microphone + speech permission to use voice.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private func askAboutFrame() {
    let question = voice.transcript
    guard let frame = streamViewModel.currentVideoFrame else { return }
    guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    Task {
      if let answer = await asker.ask(image: frame, question: question) {
        speech.speak(answer)
      }
    }
  }

  // MARK: - Transcript

  @ViewBuilder
  private var transcriptCard: some View {
    if !voice.transcript.isEmpty {
      HStack {
        Image(systemName: "quote.opening").foregroundStyle(.secondary)
        Text(voice.transcript).font(.subheadline)
        Spacer()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: - Answer

  @ViewBuilder
  private var answerCard: some View {
    if !asker.lastAnswer.isEmpty || asker.isAsking {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Answer", systemImage: "sparkles").fontWeight(.semibold)
          Spacer()
          if !asker.lastModel.isEmpty {
            Text(asker.lastModel).font(.caption2)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(Color.indigo.opacity(0.15), in: Capsule())
          }
          if !asker.lastAnswer.isEmpty {
            Button {
              if speech.isSpeaking { speech.stop() } else { speech.speak(asker.lastAnswer) }
            } label: {
              Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
            }
          }
        }
        if asker.isAsking {
          HStack(spacing: 8) { ProgressView(); Text(asker.status).font(.footnote).foregroundStyle(.secondary) }
        } else {
          Text(asker.lastAnswer).font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
    if let error = asker.lastError ?? voice.lastError
        ?? (streamViewModel.showError ? streamViewModel.errorMessage : nil) {
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
