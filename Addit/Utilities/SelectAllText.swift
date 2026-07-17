import SwiftUI
import UIKit

/// Pre-selects the text of any `UITextField` that begins editing while
/// `active` is true. SwiftUI's alert `TextField` exposes no selection API,
/// so rename popups use this to come up with the current name highlighted,
/// ready to overtype. Scope `active` to the popup's presentation so no
/// other field on screen inherits the behavior.
private struct SelectAllOnEditingBegin: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
        ) { notification in
            guard active, let field = notification.object as? UITextField else { return }
            // Deferred one runloop turn — selecting inside didBeginEditing
            // gets clobbered by the system placing the caret at the end.
            DispatchQueue.main.async { field.selectAll(nil) }
        }
    }
}

extension View {
    func selectAllInTextFields(while active: Bool) -> some View {
        modifier(SelectAllOnEditingBegin(active: active))
    }
}
