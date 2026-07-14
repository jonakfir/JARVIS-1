//
// JarvisMetaBridgeApp.swift
//
// Entry point for the JARVIS Meta Bridge companion app.
//
// Pipeline this app implements:
//   Ray-Ban Meta glasses camera
//     → Meta Wearables Device Access Toolkit (DAT) iOS SDK
//     → this SwiftUI iPhone app
//     → JARVIS `POST /api/capture/frame`
//
// The DAT SDK is configured once at launch via `Wearables.configure()`, and the
// shared `Wearables.shared` singleton is threaded down to the view models.
//
// SAFETY: the streaming path uploads with `target: false` (detection only).
// Face identification (`target: true`) happens only via a deliberate, consent-gated
// one-shot action in the UI. See JarvisFrameUploader.
//

import Foundation
import MWDATCore
import SwiftUI

@main
struct JarvisMetaBridgeApp: App {
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    // Configure the Meta Wearables DAT SDK exactly once, before first use.
    do {
      try Wearables.configure()
    } catch {
      NSLog("[JarvisMetaBridge] Failed to configure Wearables SDK: \(error)")
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    _wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(wearables: wearables, wearablesViewModel: wearablesViewModel)
    }
  }
}
