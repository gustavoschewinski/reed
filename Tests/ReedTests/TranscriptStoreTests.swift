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
    _ = store.add(text: "first", duration: 1)
    _ = store.add(text: "second", duration: 1)
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
@Test func statsInputsMirrorTheStoredRows() throws {
    let store = try TranscriptStore(inMemory: true)
    _ = store.add(text: "one two three four", duration: 5)
    let inputs = store.statsInputs()
    #expect(inputs.count == 1)
    #expect(inputs[0].wordCount == 4)
    #expect(inputs[0].durationSeconds == 5)
}
