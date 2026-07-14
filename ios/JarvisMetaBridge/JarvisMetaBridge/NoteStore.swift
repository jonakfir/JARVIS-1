//
// NoteStore.swift
//
// Local persistence for Note Buddy's saved study notes ("deck"). NoteBuddy uses
// SwiftData; here we keep it lightweight with a UserDefaults-backed JSON array so
// there's no extra framework wiring. Swap for SwiftData later if the deck grows.
//

import Foundation
import Combine

struct SavedNote: Codable, Identifiable {
  let id: UUID
  var title: String
  var summary: String
  var keyPoints: [String]
  var documentType: String
  var createdAt: Date

  init(title: String, summary: String, keyPoints: [String], documentType: String) {
    self.id = UUID()
    self.title = title
    self.summary = summary
    self.keyPoints = keyPoints
    self.documentType = documentType
    self.createdAt = Date()
  }
}

@MainActor
final class NoteStore: ObservableObject {
  @Published private(set) var notes: [SavedNote] = []

  private let key = "jarvis.noteBuddy.notes"

  init() { load() }

  func add(from response: NoteSummaryResponse) {
    let note = SavedNote(
      title: response.title,
      summary: response.summary,
      keyPoints: response.keyPoints,
      documentType: response.documentType)
    notes.insert(note, at: 0)
    save()
  }

  func delete(_ note: SavedNote) {
    notes.removeAll { $0.id == note.id }
    save()
  }

  func clear() {
    notes.removeAll()
    save()
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: key) else { return }
    if let decoded = try? JSONDecoder().decode([SavedNote].self, from: data) {
      notes = decoded
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(notes) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
}
