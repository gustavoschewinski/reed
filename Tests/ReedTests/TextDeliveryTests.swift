import Foundation
// Scoped imports of just the two AppKit symbols we need — a plain `import
// AppKit` transitively re-exports `ApplicationServices.Pasteboard`, an
// unrelated system class that collides with our own `Pasteboard` protocol.
import class AppKit.NSPasteboard
import class AppKit.NSPasteboardItem
import Testing
@testable import Reed

private final class FakePasteboard: Pasteboard {
    var items: [NSPasteboardItem]

    init(_ initial: String?) {
        if let initial {
            let item = NSPasteboardItem()
            item.setString(initial, forType: .string)
            items = [item]
        } else {
            items = []
        }
    }

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    var string: String? {
        get { items.first(where: { $0.types.contains(.string) })?.string(forType: .string) }
        set {
            if let newValue {
                let item = NSPasteboardItem()
                item.setString(newValue, forType: .string)
                items = [item]
            } else {
                items = []
            }
        }
    }

    func snapshot() -> [NSPasteboardItem] {
        items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(_ items: [NSPasteboardItem]) {
        self.items = items
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

private let testBinaryType = NSPasteboard.PasteboardType("com.reed.tests.binary")

@MainActor
@Test func deliveryPreservesNonStringClipboardContents() async {
    let original = NSPasteboardItem()
    original.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: testBinaryType)
    let board = FakePasteboard(items: [original])

    await TextDelivery.deliver(
        "hello world",
        pasteboard: board,
        canPaste: true,
        paste: { },
        restoreAfter: .milliseconds(1)
    )

    #expect(board.items.count == 1)
    #expect(board.items.first?.data(forType: testBinaryType) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
}
