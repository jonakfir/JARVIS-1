//
// WearablesViewModel.swift
//
// Manages Meta AI registration and glasses device discovery/connection using the
// DAT SDK (`MWDATCore`). Adapted from Meta's official CameraAccess sample so it
// uses only real, current SDK APIs (SDK version 0.4.0):
//   - Wearables.shared / WearablesInterface
//   - registrationState + registrationStateStream()
//   - devices + devicesStream()
//   - startRegistration() / startUnregistration()
//

import Foundation
import MWDATCore
import SwiftUI

@MainActor
final class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var registrationState: RegistrationState
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface

  /// True once the app is registered with Meta AI.
  var isRegistered: Bool { registrationState == .registered }

  /// A short human-readable label for the current registration state.
  /// Only `.registered` / `.registering` are referenced by name (confirmed SDK
  /// cases); anything else is treated as "not registered".
  var registrationLabel: String {
    if registrationState == .registered { return "Registered with Meta AI" }
    if registrationState == .registering { return "Registering…" }
    return "Not registered"
  }

  /// Human-readable list of connected device names (or a placeholder).
  var deviceSummary: String {
    guard !devices.isEmpty else { return "No glasses connected" }
    let names = devices.compactMap { wearables.deviceForIdentifier($0)?.nameOrId() }
    return names.isEmpty ? "\(devices.count) device(s)" : names.joined(separator: ", ")
  }

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState

    // Observe registration state changes.
    registrationTask = Task { [weak self] in
      guard let self else { return }
      for await state in wearables.registrationStateStream() {
        self.registrationState = state
      }
    }

    // Observe the set of available devices.
    deviceStreamTask = Task { [weak self] in
      guard let self else { return }
      for await devices in wearables.devicesStream() {
        self.devices = devices
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
  }

  /// Begin the Meta AI registration + glasses connection flow.
  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        show(error.description)
      } catch {
        show(error.localizedDescription)
      }
    }
  }

  /// Unregister / disconnect.
  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        show(error.description)
      } catch {
        show(error.localizedDescription)
      }
    }
  }

  /// Open Meta AI directly to the glasses-side DAT app update flow.
  func updateGlassesApp() {
    Task { @MainActor in
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch {
        show(error.localizedDescription)
      }
    }
  }

  private func show(_ message: String) {
    errorMessage = message
    showError = true
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }
}
