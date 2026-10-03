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
