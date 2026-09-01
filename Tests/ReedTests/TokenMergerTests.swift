import Testing
@testable import Reed

@Test func tokenMergingJoinsSubwordPiecesIntoWords() {
    // SentencePiece marks a word boundary with a leading "▁".
    let timings: [(String, Double, Double, Float)] = [
        ("▁hel", 0.0, 0.1, 1.0),
        ("lo", 0.1, 0.2, 0.8),
        ("▁world", 0.3, 0.5, 0.6),
    ]
    let words = TokenMerger.merge(
        timings.map { TokenSpan(token: $0.0, startTime: $0.1, endTime: $0.2, confidence: $0.3) },
        timeOffset: 10.0
    )

    #expect(words.count == 2)
    #expect(words[0].text == "hello")
    #expect(words[0].startTime == 10.0)
    #expect(words[0].endTime == 10.2)
    #expect(abs(words[0].confidence - 0.9) < 0.0001)  // mean of 1.0 and 0.8
    #expect(words[1].text == "world")
    #expect(words[1].startTime == 10.3)
}

@Test func tokenMergingHandlesNoTokens() {
    #expect(TokenMerger.merge([], timeOffset: 0).isEmpty)
}
