import Combine
import Foundation
import Testing
@testable import Reed

@MainActor
@Test func addingATranscriptCountsItsWords() throws {
    let store = try TranscriptStore(inMemory: true)
    let t = store.add(text: "one two three", duration: 3)
    #expect(t.wordCount == 3)
    #expect(store.all().count == 1)
}

@MainActor
@Test func wordCountIgnoresRepeatedWhitespace() throws {
    let store = try TranscriptStore(inMemory: true)
    let t = store.add(text: "  one   two \n three  ", duration: 3)
    #expect(t.wordCount == 3)
}

@MainActor
@Test func transcriptsComeBackNewestFirst() throws {
    let store = try TranscriptStore(inMemory: true)
    let first = store.add(text: "first", duration: 1)
    let second = store.add(text: "second", duration: 1)
    // Explicit, distinct dates: two inserts on a fast machine can otherwise
    // tie on `createdAt`, making the sort order arbitrary.
    first.createdAt = Date(timeIntervalSince1970: 1_000)
    second.createdAt = Date(timeIntervalSince1970: 2_000)
    #expect(store.all().first?.text == "second")
}

@MainActor
@Test func searchIsCaseInsensitive() throws {
    let store = try TranscriptStore(inMemory: true)
    _ = store.add(text: "Hello World", duration: 1)
    _ = store.add(text: "goodbye", duration: 1)
    #expect(store.search("hello").count == 1)
    #expect(store.search("").count == 2)
}

@MainActor
@Test func searchHandlesPunctuationInTheQuery() throws {
    let store = try TranscriptStore(inMemory: true)
    _ = store.add(text: "it's fine", duration: 1)
    #expect(store.search("it's").count == 1)
    #expect(store.search("nothing here").isEmpty)
}

@MainActor
@Test func deleteRemovesOnlyTheNamedRow() throws {
    let store = try TranscriptStore(inMemory: true)
    let keep = store.add(text: "keep", duration: 1)
    let drop = store.add(text: "drop", duration: 1)

    store.delete(drop)
    #expect(store.all().map(\.id) == [keep.id])
}

@MainActor
@Test func didChangeFiresOnlyAfterTheNewTranscriptIsActuallyVisible() throws {
    let store = try TranscriptStore(inMemory: true)

    // Asserting *inside* the subscription closure is the point: this is
    // exactly what a real `.onReceive(store.didChange)` reload would see.
    // Asserting after `add()` returns would pass even against the old
    // notify-before-the-change bug (`objectWillChange`), since by then the
    // mutation has long since happened — the bug only shows up mid-signal.
    var visibleInsideTheHandler = false
    var handlerRan = false
    let cancellable = store.didChange.sink {
        handlerRan = true
        visibleInsideTheHandler = store.all().contains { $0.text == "hello" }
    }

    _ = store.add(text: "hello", duration: 1)

    cancellable.cancel()
    #expect(handlerRan)
    #expect(visibleInsideTheHandler)
}

@MainActor
@Test func didChangeFiresOnlyAfterADeletionIsActuallyVisible() throws {
    let store = try TranscriptStore(inMemory: true)
    let transcript = store.add(text: "gone soon", duration: 1)

    var alreadyGoneInsideTheHandler = false
    var handlerRan = false
    let cancellable = store.didChange.sink {
        handlerRan = true
        alreadyGoneInsideTheHandler = !store.all().contains { $0.id == transcript.id }
    }

    store.delete(transcript)

    cancellable.cancel()
    #expect(handlerRan)
    #expect(alreadyGoneInsideTheHandler)
}

@MainActor
@Test func statsInputsMirrorTheStoredRows() throws {
    let store = try TranscriptStore(inMemory: true)
    let t = store.add(text: "one two three four", duration: 5)
    // An explicit, known date — not `.now` — so this test can catch an
    // implementation that hardcodes `createdAt` instead of forwarding the
    // stored row's actual date.
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    t.createdAt = fixedDate
    let inputs = store.statsInputs()
    #expect(inputs.count == 1)
    #expect(inputs[0].wordCount == 4)
    #expect(inputs[0].durationSeconds == 5)
    #expect(inputs[0].createdAt == fixedDate)
}
