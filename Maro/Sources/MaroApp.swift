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

struct LoginScreen: View {
    @ObservedObject var vm: MaroViewModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        let state = vm.state
        let ready = !state.busy && !email.isBlank && !password.isBlank
        let signIn = { if ready { vm.login(email, password) } }
        ScrollView {
            VStack(alignment: .leading, spacing: Omp.panelSpacing) {
                HStack(spacing: Omp.panelSpacing) {
                    OmpIcon(Omp.Icons.note, size: Omp.TypeSize.display, color: Omp.maro)
                        .frame(width: 52, height: 52)
                        .background(Omp.maro.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        OmpText("Omarchy Music Plugin", size: Omp.TypeSize.title, bold: true)
                        OmpText("Your desktop's music, on this phone", size: Omp.TypeSize.caption, color: Omp.muted)
                    }
                }
                VStack(alignment: .leading, spacing: Omp.spacing) {
                    OmpText("Sign in with the account your desktop uses", size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 2)
                    OmpTextField(text: $email, placeholder: "Email", keyboard: .emailAddress)
                    OmpTextField(text: $password, placeholder: "Password", password: true, onSubmit: signIn)
                    HStack(spacing: Omp.spacing) {
                        OmpButton(
                            icon: state.busy ? "" : Omp.Icons.signin,
                            text: state.busy ? "Signing in…" : "Sign in",
                            enabled: ready,
                            foreground: Omp.accent,
                            bordered: true,
                            action: signIn
                        )
                        Button { if ready { vm.register(email, password) } } label: {
                            OmpText("Create an account", size: Omp.TypeSize.bodySmall, color: Omp.muted).padding(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                    }
                    if let error = state.error { OmpText(error, size: Omp.TypeSize.caption, color: Omp.urgent, maxLines: 3) }
                }
                .padding(Omp.panelSpacing)
                .background(Omp.cardRaised, in: RoundedRectangle(cornerRadius: Omp.labelGap))
                .overlay(RoundedRectangle(cornerRadius: Omp.labelGap).stroke(Omp.softDk, lineWidth: 1))
            }
            .frame(maxWidth: 420)
            .padding(Omp.gatesGap)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Omp.background.ignoresSafeArea())
    }
}
