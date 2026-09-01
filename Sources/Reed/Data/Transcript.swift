import Foundation
import SwiftData

@Model
final class Transcript {
    var id: UUID
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var wordCount: Int

    init(text: String, createdAt: Date = .now, durationSeconds: Double) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.wordCount = text.split(whereSeparator: \.isWhitespace).count
    }
}
