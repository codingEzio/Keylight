import AppKit

@main struct TrashSafetySmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PointerConfirmation.PointerView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(view)
        var confirmations = 0
        view.action = { confirmations += 1 }
        precondition(!view.acceptsFirstResponder, "confirmation must not accept keyboard focus")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        precondition(!view.performKeyEquivalent(with: key) && confirmations == 0, "Return must not confirm")
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)! }
        let inside = NSPoint(x: 10, y: 10), outside = NSPoint(x: 150, y: 60)
        view.mouseUp(with: mouse(.leftMouseUp, inside)); precondition(confirmations == 0)
        view.mouseDown(with: mouse(.leftMouseDown, inside)); view.mouseUp(with: mouse(.leftMouseUp, outside)); precondition(confirmations == 0)
        view.mouseDown(with: mouse(.leftMouseDown, inside)); view.mouseUp(with: mouse(.leftMouseUp, inside)); precondition(confirmations == 1)
        var emptyCalls = 0
        func fakeEmpty() -> String? { emptyCalls += 1; return nil }
        precondition(TrashOperation.confirmed(status: { true }, empty: fakeEmpty) == .alreadyEmpty && emptyCalls == 0)
        precondition(TrashOperation.confirmed(status: { false }, empty: fakeEmpty) == .emptied && emptyCalls == 1)
        precondition(TrashOperation.confirmed(status: { nil }, empty: { "fixture failure" }) == .failed("fixture failure"))
        print("PASS: keyboard refusal, pointer gate, empty, nonempty and failure handling; no Finder deletion")
    }
}
