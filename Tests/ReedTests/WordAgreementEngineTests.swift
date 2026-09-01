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

/// Six words ending in three sentence enders — enough to satisfy both the
/// word-count minimum and the punctuation rule in a single pass.
private let sentence = "one two. three four. five six. seven eight"

@Test func firstPassConfirmsNothing() {
    let engine = WordAgreementEngine()
    let result = engine.process(words: words(sentence), passConfidence: 1.0)
    #expect(result.newlyConfirmedText.isEmpty)
    #expect(result.fullText == "one two. three four. five six. seven eight")
}

@Test func confirmationRequiresThreeAgreeingPasses() {
    let engine = WordAgreementEngine()
    let w = words(sentence)

    #expect(engine.process(words: w, passConfidence: 1.0).newlyConfirmedText.isEmpty)  // pass 1
    #expect(engine.process(words: w, passConfidence: 1.0).newlyConfirmedText.isEmpty)  // pass 2
    #expect(engine.process(words: w, passConfidence: 1.0).newlyConfirmedText.isEmpty)  // pass 3
    let fourth = engine.process(words: w, passConfidence: 1.0)                          // pass 4
    #expect(!fourth.newlyConfirmedText.isEmpty)
}

@Test func punctuationRuleKeepsTheLastTwoSentencesAsHypothesis() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    for _ in 0..<3 { _ = engine.process(words: w, passConfidence: 1.0) }
    let result = engine.process(words: w, passConfidence: 1.0)

    // Three enders exist; the cut is at the third from last, so only the first
    // sentence is confirmed and the final two remain open to revision.
    #expect(result.newlyConfirmedText == "one two.")
    #expect(result.fullText == "one two. three four. five six. seven eight")
}

@Test func fewerThanThreeSentenceEndersConfirmsNothing() {
    let engine = WordAgreementEngine()
    let w = words("alpha bravo. charlie delta echo foxtrot")
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
    _ = engine.process(words: b, passConfidence: 1.0)  // pass 5: agreement count 2 if reset happened

    // A correctly-resetting engine needs one more agreeing pass to confirm.
    // An engine that never reset would already have reached 3 agreements by
    // pass 5 (1 carried over from `a` + 2 from `b`) and confirmed early.
    #expect(engine.confirmedText.isEmpty)

    let sixth = engine.process(words: b, passConfidence: 1.0)  // pass 6: agreement count 3
    #expect(!sixth.newlyConfirmedText.isEmpty)
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
    _ = engine.process(words: w, passConfidence: 1.0)  // pass 5: agreement count 2 if reset happened

    // A correctly-resetting engine needs one more agreeing pass to confirm.
    // An engine that never reset would already have reached 3 agreements by
    // pass 5 (1 carried over from before the weak pass + 2 after it) and
    // confirmed early.
    #expect(engine.confirmedText.isEmpty)  // the counter restarted

    let sixth = engine.process(words: w, passConfidence: 1.0)  // pass 6: agreement count 3
    #expect(!sixth.newlyConfirmedText.isEmpty)
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
    _ = engine.process(words: plain, passConfidence: 1.0)
    let fourth = engine.process(words: shouty, passConfidence: 1.0)

    #expect(!fourth.newlyConfirmedText.isEmpty)  // treated as agreement
}

@Test func hypothesisStartTimeMovesToTheFirstUnconfirmedWord() {
    let engine = WordAgreementEngine()
    let w = words(sentence)
    for _ in 0..<4 { _ = engine.process(words: w, passConfidence: 1.0) }

    // "one two." occupies 0.0–1.9; "three" starts at 2.0.
    #expect(engine.confirmedEndTime == 1.9)
    #expect(engine.hypothesisStartTime == 2.0)
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
    for _ in 0..<4 { _ = engine.process(words: first, passConfidence: 1.0) }
    #expect(engine.confirmedText == "one two.")

    // A later stretch of speech, offset past the confirmed region.
    let second = words("nine ten. eleven twelve. thirteen fourteen. fifteen", from: 10)
    for _ in 0..<4 { _ = engine.process(words: second, passConfidence: 1.0) }
    #expect(engine.confirmedText == "one two. nine ten.")
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
