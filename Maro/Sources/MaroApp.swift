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
        GeometryReader { geo in
            // The panel's sizes are desktop points; on a phone the whole card
            // is scaled up to the screen, as the player screen is.
            let m = OmpMetrics(scale: min(max(geo.size.width / 300, 1.2), 1.5))
            form(m).environment(\.omp, m)
        }
        .background(Omp.background.ignoresSafeArea())
    }

    private func form(_ m: OmpMetrics) -> some View {
        let state = vm.state
        let ready = !state.busy && !email.isBlank && !password.isBlank
        let signIn = { if ready { vm.login(email, password) } }
        return ScrollView {
            VStack(alignment: .leading, spacing: m.pt(Omp.panelSpacing)) {
                HStack(spacing: m.pt(Omp.panelSpacing)) {
                    OmpIcon(Omp.Icons.note, size: Omp.TypeSize.display, color: Omp.maro)
                        .frame(width: m.pt(52), height: m.pt(52))
                        .background(Omp.maro.opacity(0.18), in: RoundedRectangle(cornerRadius: m.pt(10)))
                    VStack(alignment: .leading, spacing: m.pt(2)) {
                        OmpText("Omarchy Music Plugin", size: Omp.TypeSize.title, bold: true)
                        OmpText("Your desktop's music, on this phone", size: Omp.TypeSize.caption, color: Omp.muted)
                    }
                }
                VStack(alignment: .leading, spacing: m.pt(Omp.spacing)) {
                    OmpText("Sign in with the account your desktop uses", size: Omp.TypeSize.caption, color: Omp.muted, maxLines: 2)
                    OmpTextField(text: $email, placeholder: "Email", keyboard: .emailAddress)
                    OmpTextField(text: $password, placeholder: "Password", password: true, onSubmit: signIn)
                    HStack(spacing: m.pt(Omp.spacing)) {
                        OmpButton(
                            icon: state.busy ? "" : Omp.Icons.signin,
                            text: state.busy ? "Signing in…" : "Sign in",
                            enabled: ready,
                            foreground: Omp.accent,
                            bordered: true,
                            action: signIn
                        )
                        Button { if ready { vm.register(email, password) } } label: {
                            OmpText("Create an account", size: Omp.TypeSize.bodySmall, color: Omp.muted).padding(m.pt(6))
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                    }
                    if let error = state.error { OmpText(error, size: Omp.TypeSize.caption, color: Omp.urgent, maxLines: 3) }
                }
                .padding(m.pt(Omp.panelSpacing))
                .background(Omp.cardRaised, in: RoundedRectangle(cornerRadius: m.pt(Omp.labelGap)))
                .overlay(RoundedRectangle(cornerRadius: m.pt(Omp.labelGap)).stroke(Omp.softDk, lineWidth: 1))
            }
            .padding(.horizontal, m.pt(16))
            .padding(.vertical, m.pt(Omp.gatesGap))
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.8)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
