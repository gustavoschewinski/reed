import Foundation
import SwiftData

@MainActor
final class TranscriptStore: ObservableObject {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: Transcript.self, configurations: config)
    }

    func all() -> [Transcript] {
        let descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func add(text: String, duration: Double) -> Transcript {
        let transcript = Transcript(text: text, durationSeconds: duration)
        context.insert(transcript)
        do {
            try context.save()
        } catch {
            NSLog("Reed: failed to save new transcript: \(error)")
        }
        return transcript
    }

    func delete(_ transcript: Transcript) {
        context.delete(transcript)
        do {
            try context.save()
        } catch {
            NSLog("Reed: failed to save transcript deletion: \(error)")
        }
    }

    func search(_ query: String) -> [Transcript] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all() }
        // Filtering in memory: the history is small, and this avoids the
        // predicate-macro limits on localized comparison.
        return all().filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    func statsInputs() -> [StatsInput] {
        all().map {
            StatsInput(
                createdAt: $0.createdAt,
                durationSeconds: $0.durationSeconds,
                wordCount: $0.wordCount
            )
        }
    }
}
