import Testing
@testable import Reed

@Test func chunkerEmitsFixedFramesAndKeepsTheRemainder() {
    var chunker = FrameChunker(frameSize: 4)
    #expect(chunker.push([1, 2, 3]) == [])
    #expect(chunker.push([4, 5, 6, 7, 8, 9]) == [[1, 2, 3, 4], [5, 6, 7, 8]])
    #expect(chunker.push([10, 11, 12]) == [[9, 10, 11, 12]])
}

private func frame(_ v: Float, _ n: Int = 4) -> [Float] { Array(repeating: v, count: n) }

@Test func segmenterKeepsOnePreRollFrameAndOneTailFrame() {
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 100, minSeconds: 0)
    #expect(s.push(frame: frame(0), isSpeech: false) == [])
    #expect(s.push(frame: frame(1), isSpeech: true) == [])
    #expect(s.push(frame: frame(2), isSpeech: true) == [])
    let out = s.push(frame: frame(3), isSpeech: false)
    #expect(out == [SpeechSegment(startSample: 0, samples: frame(0) + frame(1) + frame(2) + frame(3))])
}

@Test func segmenterDropsSegmentsShorterThanTheMinimum() {
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 100, minSeconds: 10)
    _ = s.push(frame: frame(1), isSpeech: true)
    #expect(s.push(frame: frame(0), isSpeech: false) == [])
}

@Test func segmenterCutsAtTheMaximumAndContinues() {
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 2, minSeconds: 0)
    _ = s.push(frame: frame(0), isSpeech: false)
    #expect(s.push(frame: frame(1), isSpeech: true) == [SpeechSegment(startSample: 0, samples: frame(0) + frame(1))])
    #expect(s.push(frame: frame(2), isSpeech: true) == [])
    #expect(s.flush() == [SpeechSegment(startSample: 8, samples: frame(2))])
}

@Test func silenceOnlyProducesNothing() {
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 100, minSeconds: 0)
    for _ in 0..<50 { #expect(s.push(frame: frame(0), isSpeech: false) == []) }
    #expect(s.flush() == [])
}

@Test func nonAlignedMaxBoundaryProducesNoExceedingSegments() {
    // frameSize 4, sampleRate 4, maxSeconds 2.5 → maxSamples 10
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 2.5, minSeconds: 0)
    var allSegments: [SpeechSegment] = []

    // Push continuous speech that will be cut at max boundary.
    // We'll push enough frames to create multiple segments.
    for i in 0..<10 {
        let f = Array(repeating: Float(i), count: 4)
        let segments = s.push(frame: f, isSpeech: true)
        allSegments.append(contentsOf: segments)
    }
    allSegments.append(contentsOf: s.flush())

    // Verify no segment exceeds maxSamples (10).
    for segment in allSegments {
        #expect(segment.samples.count <= 10)
    }

    // Verify no overlap and no gap: concatenation of segments (ordered by startSample)
    // equals the original continuous speech.
    let sorted = allSegments.sorted { $0.startSample < $1.startSample }
    var expectedSample = 0
    for segment in sorted {
        #expect(segment.startSample == expectedSample)
        expectedSample += segment.samples.count
    }
}

@Test func tailFrameNotReusedAsPreRoll() {
    // Test: speech → silence (tail) → speech → silence (tail)
    // Two segments, no frame reuse, no overlap.
    var s = SpeechSegmenter(frameSize: 4, sampleRate: 4, maxSeconds: 100, minSeconds: 0)
    var allSegments: [SpeechSegment] = []

    // First segment: speech, silence (tail)
    allSegments.append(contentsOf: s.push(frame: frame(1), isSpeech: true))
    allSegments.append(contentsOf: s.push(frame: frame(0), isSpeech: false))

    // Second segment: speech, silence (tail)
    allSegments.append(contentsOf: s.push(frame: frame(2), isSpeech: true))
    allSegments.append(contentsOf: s.push(frame: frame(0), isSpeech: false))

    allSegments.append(contentsOf: s.flush())

    // Should have exactly two segments.
    #expect(allSegments.count == 2)

    // Second segment should start where first ends (no overlap).
    #expect(allSegments[1].startSample == allSegments[0].startSample + allSegments[0].samples.count)

    // First segment should contain [1,1,1,1,0,0,0,0], second should contain [2,2,2,2,0,0,0,0].
    #expect(allSegments[0].samples == frame(1) + frame(0))
    #expect(allSegments[1].samples == frame(2) + frame(0))
}
