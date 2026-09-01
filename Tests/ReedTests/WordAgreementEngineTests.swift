import Testing
@testable import Reed

/// Evenly spaced words, one per second, so timings are predictable.
private func words(_ text: String, from start: Double = 0, confidence: Float = 1.0) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { i, w in
        TimedWord(
            text: String(w),
            startTime: start + Double(i),
            endTime: start + Double(i) + 0.9,
            confidence: confidence
        )
    }
}

/// Three finished sentences and one still open — enough to satisfy both the
/// word-count minimum and the punctuation rule in a single pass.
private let sentence = "one two. three four. five six. seven eight"

@Test func firstPassConfirmsNothing() {
    let engine = WordAgreementEngine()
    let result = engine.process(words: words(sentence), passConfidence: 1.0)
    #expect(result.newlyConfirmedText.isEmpty)
    #expect(result.fullText == "one two. three four. five six. seven eight")
}

@Test func confirmationRequiresTwoAgreeingPasses() {
    let engine = WordAgreementEngine()
    let w = words(sentence)

    #expect(engine.process(words: w, passConfidence: 1.0).newlyConfirmedText.isEmpty)  // pass 1: baseline
    #expect(engine.process(words: w, passConfidence: 1.0).newlyConfirmedText.isEmpty)  // pass 2: agreement 1
    let third = engine.process(words: w, passConfidence: 1.0)                           // pass 3: agreement 2
    #expect(!third.newlyConfirmedText.isEmpty)
}

@Test func punctuationRuleKeepsTheUnfinishedSentenceAsHypothesis() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    for _ in 0..<2 { _ = engine.process(words: w, passConfidence: 1.0) }
    let result = engine.process(words: w, passConfidence: 1.0)

    // The cut lands on the most recent ender, so every finished sentence is
    // confirmed and only the one still being spoken stays open to revision.
    #expect(result.newlyConfirmedText == "one two. three four. five six.")
    #expect(result.fullText == "one two. three four. five six. seven eight")
}

@Test func anEnderOnTheLastWordDoesNotCount() {
    // Every pass ends in silence, and the model closes the word that meets
    // it with a period more often than not — a cut there would confirm a
    // word that is still being spoken.
    let engine = WordAgreementEngine()
    let w = words("alpha bravo charlie.")
    for _ in 0..<4 { _ = engine.process(words: w, passConfidence: 1.0) }
    #expect(engine.confirmedText.isEmpty)
}

@Test func disagreementResetsTheAgreementCounter() {
    let engine = WordAgreementEngine()
    let a = words(sentence)
    let b = words("nine ten. eleven twelve. thirteen fourteen. fifteen")

    _ = engine.process(words: a, passConfidence: 1.0)  // pass 1: first pass, no comparison
    _ = engine.process(words: a, passConfidence: 1.0)  // pass 2: agreement count 1
    _ = engine.process(words: b, passConfidence: 1.0)  // pass 3: disagreement — resets the counter
    _ = engine.process(words: b, passConfidence: 1.0)  // pass 4: agreement count 1 if reset happened

    // A correctly-resetting engine needs one more agreeing pass to confirm.
    // An engine that never reset would already have reached 2 agreements by
    // pass 4 (1 carried over from `a` + 1 from `b`) and confirmed early.
    #expect(engine.confirmedText.isEmpty)

    let fifth = engine.process(words: b, passConfidence: 1.0)  // pass 5: agreement count 2
    #expect(!fifth.newlyConfirmedText.isEmpty)
}

@Test func lowConfidencePassIsShownButDoesNotCountTowardAgreement() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    _ = engine.process(words: w, passConfidence: 1.0)  // pass 1: first pass, no comparison
    _ = engine.process(words: w, passConfidence: 1.0)  // pass 2: agreement count 1
    let weak = engine.process(words: w, passConfidence: 0.1)  // pass 3: low confidence — resets the counter

    #expect(weak.fullText == "one two. three four. five six. seven eight")
    #expect(weak.newlyConfirmedText.isEmpty)

    _ = engine.process(words: w, passConfidence: 1.0)  // pass 4: agreement count 1 if reset happened

    // A correctly-resetting engine needs one more agreeing pass to confirm.
    // An engine that never reset would already have reached 2 agreements by
    // pass 4 (1 carried over from before the weak pass + 1 after it) and
    // confirmed early.
    #expect(engine.confirmedText.isEmpty)  // the counter restarted

    let fifth = engine.process(words: w, passConfidence: 1.0)  // pass 5: agreement count 2
    #expect(!fifth.newlyConfirmedText.isEmpty)
}

@Test func lowConfidenceBoundaryWordsBlockConfirmation() {
    let engine = WordAgreementEngine()
    let w = words(sentence, confidence: 0.3)
    for _ in 0..<4 { _ = engine.process(words: w, passConfidence: 1.0) }
    #expect(engine.confirmedText.isEmpty)
}

@Test func normalizationIgnoresCasingAndPunctuationWhenComparing() {
    let engine = WordAgreementEngine()
    let plain = words(sentence)
    let shouty = words(sentence.uppercased())

    _ = engine.process(words: plain, passConfidence: 1.0)
    _ = engine.process(words: shouty, passConfidence: 1.0)
    let third = engine.process(words: plain, passConfidence: 1.0)

    #expect(!third.newlyConfirmedText.isEmpty)  // treated as agreement
}

@Test func hypothesisStartTimeMovesToTheFirstUnconfirmedWord() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    for _ in 0..<3 { _ = engine.process(words: w, passConfidence: 1.0) }

    // "one two. three four. five six." occupies 0.0–5.9; "seven" starts at 6.0.
    #expect(engine.confirmedEndTime == 5.9)
    #expect(engine.hypothesisStartTime == 6.0)
}

@Test func resetClearsEverything() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    for _ in 0..<4 { _ = engine.process(words: w, passConfidence: 1.0) }
    #expect(!engine.confirmedText.isEmpty)

    engine.reset()
    #expect(engine.confirmedText.isEmpty)
    #expect(engine.confirmedEndTime == 0)
    #expect(engine.hypothesisStartTime == 0)
}

@Test func emptyPassIsHarmless() {
    let engine = WordAgreementEngine()
    let result = engine.process(words: [], passConfidence: 1.0)
    #expect(result.fullText.isEmpty)
    #expect(result.newlyConfirmedText.isEmpty)
}

@Test func confirmedTextAccumulatesAcrossRounds() {
    let engine = WordAgreementEngine()
    let first = words(sentence)
    for _ in 0..<3 { _ = engine.process(words: first, passConfidence: 1.0) }
    #expect(engine.confirmedText == "one two. three four. five six.")

    // A later stretch of speech, offset past the confirmed region.
    let second = words("nine ten. eleven twelve. thirteen fourteen. fifteen", from: 10)
    for _ in 0..<3 { _ = engine.process(words: second, passConfidence: 1.0) }
    #expect(
        engine.confirmedText
            == "one two. three four. five six. nine ten. eleven twelve. thirteen fourteen.")
}

@Test func normalizationKeepsApostrophesSoContractionsDoNotCollideWithLookalikes() {
    let contraction = TimedWord(text: "it's", startTime: 0, endTime: 1)
    let possessive = TimedWord(text: "its", startTime: 0, endTime: 1)
    #expect(contraction.normalizedText != possessive.normalizedText)
}

@Test func normalizationTreatsApostropheVariantsAsEqual() {
    let straight = TimedWord(text: "it's", startTime: 0, endTime: 1)
    let curly = TimedWord(text: "it\u{2019}s", startTime: 0, endTime: 1)
    #expect(straight.normalizedText == curly.normalizedText)
}

@Test func normalizationKeepsWereDistinctFromWereContraction() {
    let contraction = TimedWord(text: "we're", startTime: 0, endTime: 1)
    let plain = TimedWord(text: "were", startTime: 0, endTime: 1)
    #expect(contraction.normalizedText != plain.normalizedText)
}
