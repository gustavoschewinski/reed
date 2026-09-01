import Testing
@testable import Reed

@Test func packageBuildsAndTestsRun() {
    #expect(Reed.version == "0.1.0")
}
