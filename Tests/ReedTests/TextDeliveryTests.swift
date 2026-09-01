import Testing
@testable import Reed

private final class FakePasteboard: Pasteboard {
    var string: String?
    var history: [String?] = []

    init(_ initial: String?) {
        string = initial
        history = [initial]
    }
}

@MainActor
@Test func deliveryPastesThenRestoresThePreviousClipboard() async {
    let board = FakePasteboard("something the user had copied")
    var pastedWhileSet: String?

    await TextDelivery.deliver(
        "hello world",
        pasteboard: board,
        canPaste: true,
        paste: { pastedWhileSet = board.string },
        restoreAfter: .milliseconds(1)
    )

    #expect(pastedWhileSet == "hello world")
    #expect(board.string == "something the user had copied")
}

@MainActor
@Test func withoutAccessibilityTheTextStaysOnTheClipboard() async {
    let board = FakePasteboard("old")
    var pasted = false

    await TextDelivery.deliver(
        "hello world",
        pasteboard: board,
        canPaste: false,
        paste: { pasted = true },
        restoreAfter: .milliseconds(1)
    )

    #expect(pasted == false)
    #expect(board.string == "hello world")  // not restored — it is the result
}

@MainActor
@Test func emptyTextIsNotDelivered() async {
    let board = FakePasteboard("old")
    var pasted = false

    await TextDelivery.deliver(
        "   ",
        pasteboard: board,
        canPaste: true,
        paste: { pasted = true },
        restoreAfter: .milliseconds(1)
    )

    #expect(pasted == false)
    #expect(board.string == "old")
}
