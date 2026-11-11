import AppKit
import SwiftUI

// Only an actual pointer press and release inside this view invokes the action.
// It cannot become first responder and exposes no keyboard/default-button action.
struct PointerConfirmation: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> PointerView { let view = PointerView(); view.action = action; return view }
    func updateNSView(_ view: PointerView, context: Context) { view.action = action }
    final class PointerView: NSView {
        var action: (() -> Void)?
        private var pressed = false
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
        override func mouseUp(with event: NSEvent) {
            let confirmed = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
            pressed = false
            if confirmed { action?() }
        }
    }
}

struct EmptyTrashView: View {
    let appearance: LauncherAppearance
    let cancel: () -> Void
    @State private var running = false
    @State private var error: String?
    @State private var done = false
    @FocusState private var focused: Bool

    private func empty() {
        guard !running, !done else { return }
        running = true; error = nil
        // Finder owns Trash semantics, including other mounted volumes.
        DispatchQueue.main.async {
            var details: NSDictionary?
            let result = NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&details)
            running = false
            if result == nil { error = (details?[NSAppleScript.errorMessage] as? String) ?? NSLocalizedString("Could not empty the Trash.", comment: "") }
            else { done = true }
        }
    }
    private func choice(_ title: LocalizedStringKey, destructive: Bool, action: @escaping () -> Void) -> some View {
        let color = destructive ? appearance.accent : appearance.foreground
        return Text(title).font(.system(size: 15, weight: .semibold)).frame(width: 150, height: 40)
            .foregroundStyle(color)
            .background(color.opacity(destructive ? 0.16 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: appearance.rowCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: appearance.rowCornerRadius).strokeBorder(color.opacity(destructive ? 0.7 : 0.25), lineWidth: 1))
            .overlay { PointerConfirmation(action: action) }
    }
    var body: some View {
        VStack(spacing: 0) {
            LauncherHeader(appearance: appearance, showSearchIcon: false) { Text("Empty Trash").font(appearance.rowFont); Spacer() }
            VStack(spacing: 18) {
                Image(systemName: done ? "checkmark.circle" : "trash").font(.system(size: 30)).foregroundStyle(appearance.accent)
                Text(done ? "Trash emptied" : "Empty the Trash?").font(.system(size: 20, weight: .semibold))
                if !done { Text("Items will be permanently deleted. Choose with the mouse.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled) }
                if running { ProgressView().controlSize(.small) }
                else if done { choice("Close", destructive: false, action: cancel) }
                else { HStack(spacing: 12) { choice("No", destructive: false, action: cancel); choice("Yes, empty Trash", destructive: true, action: empty) } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.focusable().focusEffectDisabled().focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onKeyPress(.return) { .handled }
            .onKeyPress(.space) { .handled }
    }
}
