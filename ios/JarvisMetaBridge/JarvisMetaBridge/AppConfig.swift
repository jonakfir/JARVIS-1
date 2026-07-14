//
// AppConfig.swift
//
// Centralized configuration for the JARVIS Meta Bridge app.
//
// The ONLY thing you normally need to change is the JARVIS backend URL.
// Set `defaultBackendURLString` below to your Mac's LAN address, e.g.
// "http://192.168.1.100:8000". You can also override it at runtime from the
// in-app Settings screen (persisted in UserDefaults) without recompiling.
//

import Foundation
import Combine

@MainActor
final class AppConfig: ObservableObject {
  static let shared = AppConfig()

  /// Your Mac's LAN IP + port. This is the single source of truth for the default
  /// backend location — it is NOT hardcoded anywhere else. Pre-filled with this
  /// Mac's current Wi-Fi IP; if your network/IP changes, edit here or use the
  /// in-app Settings screen (which persists an override).
  static let defaultBackendURLString = "http://192.168.68.65:8000"

  /// The immutable source type JARVIS records for every frame from this app.
  static let frameSource = "meta_glasses_ios"

  private static let backendURLKey = "jarvis.backendURLString"

  /// The active backend base URL string. Editing this persists it and it takes
  /// effect on the next upload.
  @Published var backendURLString: String {
    didSet {
      UserDefaults.standard.set(backendURLString, forKey: Self.backendURLKey)
    }
  }

  private init() {
    let stored = UserDefaults.standard.string(forKey: Self.backendURLKey)
    backendURLString = stored?.isEmpty == false ? stored! : Self.defaultBackendURLString
  }

  /// Build a fully-qualified endpoint URL for a backend path, or nil if the base
  /// URL is malformed. e.g. endpoint("api/capture/frame").
  func endpoint(_ path: String) -> URL? {
    let trimmed = backendURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var base = URL(string: trimmed) else { return nil }
    base.appendPathComponent(path)
    return base
  }

  /// Endpoint for streaming detection frames (widget #1, Identify Person).
  var frameEndpointURL: URL? { endpoint("api/capture/frame") }

  /// Endpoint for single-frame scene description (widget #2, Scene Describe).
  var describeEndpointURL: URL? { endpoint("api/vision/describe") }

  func resetToDefault() {
    backendURLString = Self.defaultBackendURLString
  }
}
