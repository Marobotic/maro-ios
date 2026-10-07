import SwiftUI

@main
struct MaroApp: App {
    @StateObject private var vm = MaroViewModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if vm.state.signedIn {
                    HomeScreen(vm: vm)
                } else {
                    LoginScreen(vm: vm)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Omp.accent)
        }
    }
}

/**
 * Sign in or create an account: the usual shape (logo, a Sign in / Create
 * account switch, labelled fields, one big button), in the panel's colours
 * and font, at phone sizes rather than the panel's desktop ones.
 */
struct LoginScreen: View {
    @ObservedObject var vm: MaroViewModel
    @State private var creating = false
    @State private var forgot = false // "Forgot password?": email only, sends a reset link
    @State private var notice: String?
    @State private var sending = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var problem: String?

    var body: some View {
        let state = vm.state
        let error = problem ?? (forgot ? nil : state.error)
        ScrollView {
            VStack(spacing: 0) {
                Image("LaunchNote").resizable().scaledToFit().frame(width: 84, height: 84)
                Spacer().frame(height: 16)
                text("Jukebox", 22, Omp.foreground, bold: true)
                Spacer().frame(height: 6)
                text("Your music, on every device", 14, Omp.muted)
                Spacer().frame(height: 28)

                if forgot {
                    text("Forgot your password? Enter your email and we'll send you a link to choose a new one.", 14, Omp.foreground, align: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    modeSwitch
                }
                Spacer().frame(height: 22)

                field("Email", $email, secure: false, keyboard: .emailAddress, submitsForm: forgot)
                if !forgot {
                    Spacer().frame(height: 14)
                    field("Password", $password, secure: !showPassword, trailing: showPassword ? "Hide" : "Show",
                          onTrailing: { showPassword.toggle() }, submitsForm: !creating)
                    if creating {
                        Spacer().frame(height: 14)
                        field("Confirm password", $confirm, secure: !showPassword, submitsForm: true)
                    }
                    if !creating {
                        Spacer().frame(height: 10)
                        Button { setMode(creating: false, forgot: true) } label: {
                            text("Forgot password?", 13, Omp.muted).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Spacer().frame(height: 8)
                    text(creating ? "At least 8 characters." : "The same account as Hourglass. Your other devices use it too.",
                         12, Omp.muted, align: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notice {
                    Spacer().frame(height: 14)
                    text(notice, 13, Omp.themeAccent, align: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    Spacer().frame(height: 14)
                    text(error, 13, Omp.urgent, align: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer().frame(height: 22)
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if state.busy || sending { ProgressView().tint(.white) }
                        text(buttonTitle(state.busy), 16, .white, bold: true)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Omp.themeAccent.opacity(state.busy || sending ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(state.busy || sending)

                Spacer().frame(height: 18)
                HStack(spacing: 0) {
                    text(forgot ? "Remembered it? " : creating ? "Already have an account? " : "New here? ", 14, Omp.muted)
                    Button {
                        setMode(creating: !creating && !forgot, forgot: false)
                    } label: {
                        text(forgot || creating ? "Sign in" : "Create an account", 14, Omp.themeAccent, bold: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.85)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Omp.background.ignoresSafeArea())
    }

    private func buttonTitle(_ busy: Bool) -> String {
        if forgot { return sending ? "Sending…" : "Send reset link" }
        return busy ? (creating ? "Creating account…" : "Signing in…") : (creating ? "Create account" : "Sign in")
    }

    private func setMode(creating: Bool, forgot: Bool) {
        self.creating = creating
        self.forgot = forgot
        problem = nil
        notice = nil
    }

    // Checked here first, so the common mistakes never make a round trip.
    private func submit() {
        if vm.state.busy || sending { return }
        let e = email.trimmingCharacters(in: .whitespaces)
        notice = nil
        if forgot {
            if e.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
                problem = "Enter a valid email address."
                return
            }
            problem = nil
            sending = true
            Task {
                let err = await vm.forgotPassword(e)
                problem = err
                if err == nil { notice = "If \(e) has an account, a reset link is on its way. Open it on any device; it works for one hour." }
                sending = false
            }
            return
        }
        if e.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            problem = "Enter a valid email address."
        } else if password.count < 8 {
            problem = "The password needs at least 8 characters."
        } else if creating && confirm != password {
            problem = "The passwords do not match."
        } else {
            problem = nil
            if creating { vm.register(e, password) } else { vm.login(e, password) }
        }
    }

    private func text(_ s: String, _ size: CGFloat, _ color: Color, bold: Bool = false, align: TextAlignment = .center) -> some View {
        Text(s).font(Omp.font(size, bold: bold)).foregroundColor(color).multilineTextAlignment(align)
    }

    /** The two-way Sign in / Create account switch. */
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach([(false, "Sign in"), (true, "Create account")], id: \.1) { value, label in
                let on = creating == value
                Button {
                    creating = value
                    problem = nil
                } label: {
                    text(label, 14, on ? Omp.foreground : Omp.muted, bold: on)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(on ? Omp.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: 44)
        .background(Omp.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Omp.softDk, lineWidth: 1))
    }

    private func field(_ label: String, _ value: Binding<String>, secure: Bool, keyboard: UIKeyboardType = .default,
                       trailing: String? = nil, onTrailing: @escaping () -> Void = {}, submitsForm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            text(label, 13, Omp.foreground).padding(.leading, 2)
            HStack(spacing: 10) {
                Group {
                    if secure {
                        SecureField("", text: value)
                    } else {
                        TextField("", text: value).keyboardType(keyboard)
                    }
                }
                .font(Omp.font(16))
                .foregroundColor(Omp.foreground)
                .tint(Omp.themeAccent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(submitsForm ? .go : .next)
                .onSubmit { if submitsForm { submit() } }
                .onChange(of: value.wrappedValue) { problem = nil }
                if let trailing {
                    Button(action: onTrailing) { text(trailing, 13, Omp.muted) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Omp.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Omp.borderColor, lineWidth: 1))
        }
    }
}
