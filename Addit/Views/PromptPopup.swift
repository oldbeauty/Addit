import SwiftUI

/// A text-entry popup shaped like a system alert — the app's rename and
/// description prompts.
///
/// It exists for one reason. `UIAlertController`'s action buttons track like
/// menu items: they light up when a finger *drags onto* them and fire on
/// release, whether or not the touch went down there. So selecting text in
/// the alert's own field and sliding a finger past the field's edge lands on
/// "Cancel" and throws the edit away — the alert doing exactly what UIKit
/// designed it to do, with no API to switch it off.
///
/// A SwiftUI `Button` has the opposite contract, the same one `UIButton` has
/// always had: it only fires for a touch that went **down** inside it, and a
/// finger arriving by drag is ignored. Drawing the buttons ourselves is the
/// whole fix. Everything else in this file is just keeping the popup looking
/// and behaving like the alert it replaces — centered card, hairline-split
/// action row, text pre-selected and ready to overtype.
private struct PromptPopup<Subject>: View {
    let title: String
    let message: String?
    let placeholder: String
    let multiline: Bool
    let saveTitle: String
    let subject: Subject
    @Binding var text: String
    let onSave: (Subject) -> Void
    let dismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.uiHeadline)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(.uiFootnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                field
            }
            .padding(.horizontal, 16)
            .padding(.top, 19)
            .padding(.bottom, 16)

            Divider()

            HStack(spacing: 0) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(PromptButtonStyle())
                Divider()
                Button(saveTitle) { save() }
                    .buttonStyle(PromptButtonStyle(weight: .semibold))
            }
            .frame(height: 44)
        }
        .frame(width: 270)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        // Single-line fields come up highlighted, ready to overtype. A
        // description doesn't: prose is usually amended, not replaced, and
        // arriving with the whole thing selected makes the next keystroke
        // destructive.
        .selectAllInTextFields(while: !multiline)
        .onAppear {
            // Deferred a runloop turn, for the same reason the select-all
            // helper defers: on the frame the card appears the field isn't in
            // the responder chain yet, and focus set now is dropped.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    @ViewBuilder
    private var field: some View {
        if multiline {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(3...6)
                .focused($isFocused)
                .padding(8)
                .background(fieldBackground)
        } else {
            TextField(placeholder, text: $text)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(fieldBackground)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }

    private func save() {
        onSave(subject)
        dismiss()
    }
}

/// An alert-style action: fills its half of the row, tints while held.
///
/// The press highlight is the visible half of the fix — it appears only when
/// a finger goes down on the button, so a finger that merely slides across on
/// its way out of the text field never lights anything up, and nothing fires
/// when it lifts.
private struct PromptButtonStyle: ButtonStyle {
    var weight: Font.Weight = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiBody.weight(weight))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0))
    }
}

private struct PromptPopupModifier<Subject>: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let subject: Subject?
    let message: String?
    let placeholder: String
    @Binding var text: String
    let multiline: Bool
    let saveTitle: String
    let onSave: (Subject) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            // The `if` sits inside a ZStack that is always there, so the
            // default opacity transition has a stable container to run in and
            // one `.animation(value:)` drives both halves.
            ZStack {
                if isPresented, let subject {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        // Swallows every touch aimed at the screen behind,
                        // like an alert's dimming view. Deliberately not a
                        // dismiss target: an alert doesn't close on an
                        // outside tap either.
                        .onTapGesture {}

                    PromptPopup(
                        title: title,
                        message: message,
                        placeholder: placeholder,
                        multiline: multiline,
                        saveTitle: saveTitle,
                        subject: subject,
                        text: $text,
                        onSave: onSave,
                        dismiss: { isPresented = false }
                    )
                }
            }
            .animation(.snappy(duration: 0.2), value: isPresented)
        }
    }
}

extension View {
    /// Presents a text-entry popup. Deliberately mirrors
    /// `.alert(_:isPresented:presenting:)` — `presenting` hands the subject to
    /// the save action rather than having it read state that dismissal may
    /// already have cleared.
    ///
    /// Use this rather than an `.alert` containing a `TextField`; see
    /// `PromptPopup` for why that combination loses edits.
    func prompt<Subject>(
        _ title: String,
        isPresented: Binding<Bool>,
        presenting subject: Subject?,
        message: String? = nil,
        placeholder: String,
        text: Binding<String>,
        multiline: Bool = false,
        saveTitle: String = "Save",
        onSave: @escaping (Subject) -> Void
    ) -> some View {
        modifier(PromptPopupModifier(
            title: title,
            isPresented: isPresented,
            subject: subject,
            message: message,
            placeholder: placeholder,
            text: text,
            multiline: multiline,
            saveTitle: saveTitle,
            onSave: onSave
        ))
    }
}
