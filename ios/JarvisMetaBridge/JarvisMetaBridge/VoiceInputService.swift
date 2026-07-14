//
// VoiceInputService.swift
//
// On-device speech-to-text for the hands-free "Voice Guide" widget.
//
// Uses Apple's first-party Speech framework (SFSpeechRecognizer) with the mic
// captured via AVAudioEngine. When the Ray-Ban Meta glasses are connected they act
// as a standard Bluetooth headset, so `.allowBluetooth` routes their mic here —
// the same audio path OpenGlasses uses (the DAT SDK has no microphone API).
//
// NOTE ON WHISPERKIT: OpenGlasses uses SenseVoice (sherpa-onnx), not WhisperKit.
// Apple's Speech framework is used here because it's on-device capable, needs no
// external dependency, and its API is stable. To swap in WhisperKit later, replace
// this class behind the same start()/stop()/transcript interface.
//

import AVFoundation
import Combine
import Speech

@MainActor
final class VoiceInputService: NSObject, ObservableObject {
  @Published private(set) var transcript: String = ""
  @Published private(set) var isListening: Bool = false
  @Published private(set) var authorized: Bool = false
  @Published private(set) var lastError: String?

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  /// Request mic + speech-recognition permission. Safe to call repeatedly.
  func requestAuthorization() async {
    let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
      SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
    }
    let micGranted: Bool = await withCheckedContinuation { cont in
      AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
    }
    authorized = (speechStatus == .authorized) && micGranted
    if !authorized {
      lastError = "Microphone or speech recognition permission not granted."
    }
  }

  /// Start listening; partial results stream into `transcript`.
  func start() {
    guard !isListening else { return }
    guard let recognizer, recognizer.isAvailable else {
      lastError = "Speech recognition unavailable on this device."
      return
    }
    guard authorized else {
      lastError = "Grant microphone + speech permission first."
      return
    }

    transcript = ""
    lastError = nil

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      req.requiresOnDeviceRecognition = true
    }
    request = req

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord, mode: .measurement,
        options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      lastError = "Audio session error: \(error.localizedDescription)"
      return
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      lastError = "Couldn't start audio engine: \(error.localizedDescription)"
      cleanup()
      return
    }

    isListening = true
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let result {
          self.transcript = result.bestTranscription.formattedString
        }
        if error != nil || (result?.isFinal ?? false) {
          self.stop()
        }
      }
    }
  }

  /// Stop listening. `transcript` retains the final text.
  func stop() {
    guard isListening else { return }
    cleanup()
    isListening = false
  }

  private func cleanup() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
  }
}
