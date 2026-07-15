//
// ContentView.swift
//
// Home screen for the Glasses Widgets app: a gallery of widgets that run on top
// of the Meta glasses camera + JARVIS backend. Widget #1 is "Identify Person".
// Add future widgets as new cards here.
//

import MWDATCore
import SwiftUI
import UIKit

struct ContentView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  @StateObject private var streamViewModel: StreamSessionViewModel
  @StateObject private var identificationViewModel: OneShotIdentificationViewModel
  @StateObject private var config = AppConfig.shared

  init(wearables: WearablesInterface, wearablesViewModel: WearablesViewModel) {
    self.wearablesViewModel = wearablesViewModel
    let uploader = JarvisFrameUploader(config: .shared)
    _streamViewModel = StateObject(
      wrappedValue: StreamSessionViewModel(wearables: wearables, uploader: uploader))
    let capture = OneShotCaptureCoordinator(factory: DATOneShotCaptureSessionFactory(wearables: wearables))
    let display = GlassesDisplayPresenter(display: DATIdentityDisplayConnection(wearables: wearables))
    _identificationViewModel = StateObject(wrappedValue: OneShotIdentificationViewModel(
      captureJPEG: { try await capture.captureJPEG() }, cancelCapture: { capture.cancel() },
      submit: { data in try await IdentificationAPIClient(config: .shared).submit(jpegData: data) },
      status: { id in try await IdentificationAPIClient(config: .shared).status(requestID: id) },
      showCard: { card in try await display.showCard(card) }, cancelDisplay: { display.cancel() }))
  }

  private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          header

          LazyVGrid(columns: columns, spacing: 14) {
            // Widget #1 — live.
            NavigationLink {
              IdentifyPersonWidgetView(
                wearablesViewModel: wearablesViewModel,
                streamViewModel: streamViewModel,
                identificationViewModel: identificationViewModel,
                config: config)
            } label: {
              WidgetCard(
                title: "Identify Person",
                subtitle: identifySubtitle,
                systemImage: "person.fill.viewfinder",
                tint: .purple,
                enabled: true)
            }
            .buttonStyle(.plain)

            // Widget #2 — live.
            NavigationLink {
              SceneDescribeWidgetView(
                wearablesViewModel: wearablesViewModel,
                streamViewModel: streamViewModel,
                config: config)
            } label: {
              WidgetCard(
                title: "Scene Describe",
                subtitle: "What am I looking at?",
                systemImage: "text.viewfinder",
                tint: .green,
                enabled: true)
            }
            .buttonStyle(.plain)

            // Widget #3 — live.
            NavigationLink {
              ReadItWidgetView(
                wearablesViewModel: wearablesViewModel,
                streamViewModel: streamViewModel,
                config: config)
            } label: {
              WidgetCard(
                title: "Read It",
                subtitle: "Read text aloud",
                systemImage: "doc.text.viewfinder",
                tint: .blue,
                enabled: true)
            }
            .buttonStyle(.plain)

            // Widget #4 — live (NoteBuddy-style).
            NavigationLink {
              NoteBuddyWidgetView(
                wearablesViewModel: wearablesViewModel,
                streamViewModel: streamViewModel,
                config: config)
            } label: {
              WidgetCard(
                title: "Note Buddy",
                subtitle: "Document → study note",
                systemImage: "doc.text.image",
                tint: .pink,
                enabled: true)
            }
            .buttonStyle(.plain)

            // Widget #5 — live (OpenGlasses-style: voice + model freedom).
            NavigationLink {
              VoiceGuideWidgetView(
                wearablesViewModel: wearablesViewModel,
                streamViewModel: streamViewModel,
                config: config)
            } label: {
              WidgetCard(
                title: "Voice Guide",
                subtitle: "Ask Claude, hands-free",
                systemImage: "waveform.and.person.filled",
                tint: .indigo,
                enabled: true)
            }
            .buttonStyle(.plain)

            // Future widgets — placeholders to grow into (see README roadmap).
            WidgetCard(
              title: "Translate",
              subtitle: "Coming soon",
              systemImage: "character.bubble",
              tint: .orange,
              enabled: false)
          }
        }
        .padding()
      }
      .navigationTitle("Glasses Widgets")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: "eyeglasses")
        Text(wearablesViewModel.isRegistered ? wearablesViewModel.deviceSummary : "Not connected")
          .foregroundStyle(.secondary)
      }
      .font(.subheadline)
      Text("Widgets that run on your Meta glasses.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var identifySubtitle: String {
    switch identificationViewModel.state {
    case .capturing: return "Capturing one photo…"
    case .identifying, .enriching: return "Identifying…"
    case .nameDisplayed(let name): return name
    case .enrichedCardDisplayed(let name, _, _): return name
    case .notIdentified: return "Not identified"
    case .failed: return "Needs attention"
    case .idle: return "Tap to identify once"
    }
  }
}

/// A single tappable widget tile on the hub.
private struct WidgetCard: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let tint: Color
  let enabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 12)
          .fill(tint.opacity(enabled ? 0.18 : 0.10))
          .frame(width: 48, height: 48)
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(enabled ? tint : .secondary)
      }
      Text(title)
        .font(.headline)
        .foregroundStyle(enabled ? .primary : .secondary)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Image(systemName: enabled ? "chevron.right.circle.fill" : "lock.fill")
          .foregroundStyle(enabled ? tint : .secondary)
      }
    }
    .padding()
    .frame(height: 150, alignment: .topLeading)
    .frame(maxWidth: .infinity)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(enabled ? tint.opacity(0.35) : Color.clear, lineWidth: 1))
    .opacity(enabled ? 1 : 0.6)
  }
}
