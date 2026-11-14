import SwiftUI
import UIKit

/// Tapping anywhere that isn't a text field closes the keyboard, on every
/// screen and sheet (user, 2026-09-28: the product page's comment field kept
/// its keyboard up over the page after tapping elsewhere).
///
/// One tap recognizer on the window rather than a gesture per screen: it
/// never cancels the tap, so whatever was tapped — a button, a row, Post —
/// still gets it, and a tap on a text field (moving between fields) is
/// ignored instead of closing the keyboard and reopening it.
private final class KeyboardDismissTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(close))
        cancelsTouchesInView = false
        delaysTouchesEnded = false
        delegate = self
    }

    @objc private func close() { view?.endEditing(true) }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v {
            if current is UITextField || current is UITextView { return false }
            v = current.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Puts the recognizer on the window this view lands in, once.
///
/// Off while search is open: the search screen runs its own keyboard (it
/// closes on scroll), and its clear button and "+" fill buttons exist to keep
/// typing — closing the keyboard on those taps broke search (2026-09-28).
struct KeyboardDismissInstaller: UIViewRepresentable {
    var enabled = true

    func makeUIView(context: Context) -> UIView { Host() }
    func updateUIView(_ view: UIView, context: Context) { (view as? Host)?.enabled = enabled }

    private final class Host: UIView {
        private weak var tap: KeyboardDismissTap?
        var enabled = true { didSet { tap?.isEnabled = enabled } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            if let existing = window.gestureRecognizers?.compactMap({ $0 as? KeyboardDismissTap }).first {
                tap = existing
            } else {
                let added = KeyboardDismissTap()
                window.addGestureRecognizer(added)
                tap = added
            }
            tap?.isEnabled = enabled
        }
    }
}
