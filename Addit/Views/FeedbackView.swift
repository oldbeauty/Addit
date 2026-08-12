import MessageUI
import SwiftUI
import UIKit

/// "Pls report bugs", under Settings in the library's account menu: free-text
/// bug reports and complaints.
///
/// Text is collected in the app's own UI, then handed to Mail already addressed
/// and filled in. iOS gives an app no way to send mail by itself — without a
/// server of our own the only routes are `MFMailComposeViewController` or a
/// `mailto:` URL, and both end with the user pressing Send. That's deliberate
/// on Apple's part (a silent send is a spam vector), so the second tap isn't
/// something that can be designed away from inside the app.
struct FeedbackSheet: View {
    /// Where reports go.
    static let recipient = "waterloo.sunset.fine@gmail.com"

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var themeService

    @State private var text = ""
    @State private var isComposingMail = false
    @State private var mailFailed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($isFocused)
                    .font(.uiBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                // TextEditor has no placeholder of its own, and the prompt is
                // the whole instruction here — so it can't just be the title.
                if text.isEmpty {
                    Text("Enter bugs or complaints")
                        .font(.uiBody)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 21)
                        .padding(.top, 20)
                        .allowsHitTesting(false)
                }
            }
            .appBackground()
            .navigationTitle("Pls report bugs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .fontWeight(.semibold)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(themeService.accentColor)
        .onAppear { isFocused = true }
        .sheet(isPresented: $isComposingMail) {
            MailComposer(
                recipient: Self.recipient,
                subject: "Addit feedback",
                body: text + Self.diagnostics
            ) {
                isComposingMail = false
                dismiss()
            }
            .ignoresSafeArea()
        }
        .alert("Couldn't Open Mail", isPresented: $mailFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("No mail account is set up on this device. Send your report to \(Self.recipient).")
        }
    }

    private func send() {
        // `canSendMail()` is false whenever the built-in Mail app has no
        // account — common for people who only use Gmail's own app — so fall
        // back to a mailto: URL, which any installed mail client can claim.
        if MFMailComposeViewController.canSendMail() {
            isComposingMail = true
            return
        }
        var components = URLComponents(string: "mailto:\(Self.recipient)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "Addit feedback"),
            URLQueryItem(name: "body", value: text + Self.diagnostics),
        ]
        guard let url = components?.url, UIApplication.shared.canOpenURL(url) else {
            mailFailed = true
            return
        }
        UIApplication.shared.open(url)
        dismiss()
    }

    /// Appended to every report. A bug report without a build number is a
    /// guessing game, and the user sees all of this in the composer before it
    /// goes anywhere.
    private static var diagnostics: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return """


        —
        Addit \(version) (\(build)) · \(device.systemName) \(device.systemVersion) · \(hardwareModel)
        """
    }

    /// `UIDevice.model` only ever says "iPhone"; the marketing-ish identifier
    /// (`iPhone17,1`) is the one that tells you which device it was.
    private static var hardwareModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

/// `MFMailComposeViewController` in SwiftUI clothing. Nothing is sent until the
/// user taps Send inside it.
private struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) { [onFinish] in onFinish() }
        }
    }
}
