//
// NoteBuddyWidgetView.swift
//
// Widget #4 in the Glasses Widgets app: "Note Buddy".
//
// Reimplements Alphonso84/RayBan_Meta_NoteBuddy: point the glasses at a document,
// capture a high-res still, and JARVIS turns it into a study note (title, summary,
// key points, doc type). Notes are saved into a local deck and can be read aloud.
//

import MWDATCore
import SwiftUI
import UIKit

struct NoteBuddyWidgetView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var config: AppConfig
  @StateObject private var summarizer = NoteSummaryService()
  @StateObject private var store = NoteStore()
  @StateObject private var speech = SpeechService()

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        preview
        controls
        if summarizer.lastNote != nil { noteCard }
        if !store.notes.isEmpty { deck }
        errorCard
      }
      .padding()
    }
    .navigationTitle("Note Buddy")
    .navigationBarTitleDisplayMode(.inline)
    .task { await streamViewModel.refreshPermission() }
    .onAppear { streamViewModel.detectionUploadsEnabled = false }
    .onDisappear {
      streamViewModel.detectionUploadsEnabled = true
      speech.stop()
    }
    // Summarize as soon as a fresh high-res still arrives.
    .onChange(of: streamViewModel.capturedPhotoVersion) { _, _ in
      guard let photo = streamViewModel.capturedPhoto else { return }
      Task { await summarizer.summarize(image: photo) }
    }
  }

  // MARK: - Preview

  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
      if let shot = streamViewModel.capturedPhoto {
        Image(uiImage: shot).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12))
      } else if let frame = streamViewModel.currentVideoFrame {
        Image(uiImage: frame).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(alignment: .bottom) {
            Text("Frame the document, then Capture")
              .font(.caption).padding(6)
              .background(.ultraThinMaterial, in: Capsule())
              .padding(8)
          }
      } else {
        VStack(spacing: 8) {
          Image(systemName: "doc.viewfinder").font(.system(size: 40))
          Text(streamViewModel.isStreaming ? "Point at a document…" : "Start the stream to begin")
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
        streamViewModel.capturePhoto()
      } label: {
        Label(summarizer.isSummarizing ? "Summarizing…" : "Capture document",
              systemImage: "doc.text.magnifyingglass")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.pink)
      .disabled(!streamViewModel.isStreaming || summarizer.isSummarizing)

      if summarizer.isSummarizing {
        HStack(spacing: 8) { ProgressView(); Text(summarizer.status).font(.footnote).foregroundStyle(.secondary) }
      }
    }
  }

  // MARK: - Latest note

  @ViewBuilder
  private var noteCard: some View {
    if let note = summarizer.lastNote {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(note.title.isEmpty ? "Untitled note" : note.title).font(.headline)
          Spacer()
          if !note.documentType.isEmpty {
            Text(note.documentType)
              .font(.caption2)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(Color.pink.opacity(0.15), in: Capsule())
          }
        }
        Text(note.summary).font(.subheadline)
        if !note.keyPoints.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(note.keyPoints.enumerated()), id: \.offset) { _, point in
              Text("• \(point)").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        HStack(spacing: 12) {
          Button {
            store.add(from: note)
          } label: { Label("Save to deck", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(.pink)
          Button {
            speech.speak(spoken(note))
          } label: { Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2") }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(Color(.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  private func spoken(_ note: NoteSummaryResponse) -> String {
    var parts = [note.title, note.summary]
    parts.append(contentsOf: note.keyPoints)
    return parts.filter { !$0.isEmpty }.joined(separator: ". ")
  }

  // MARK: - Deck

  private var deck: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Deck · \(store.notes.count)").fontWeight(.semibold)
        Spacer()
        Button("Clear", role: .destructive) { store.clear() }.font(.footnote)
      }
      ForEach(store.notes) { note in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "Untitled" : note.title).font(.subheadline).fontWeight(.medium)
            Text(note.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Button(role: .destructive) {
            store.delete(note)
          } label: {
            Image(systemName: "trash").foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
        Divider()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  // MARK: - Errors

  @ViewBuilder
  private var errorCard: some View {
    if let error = summarizer.lastError ?? (streamViewModel.showError ? streamViewModel.errorMessage : nil) {
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
