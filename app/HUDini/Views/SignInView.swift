import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var selectedTab: AuthTab = .login
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var preferredSourceLanguageCode: String = "es"
    @FocusState private var focusedField: Field?

    private enum AuthTab: String, CaseIterable {
        case login = "Login"
        case signup = "Create Account"
    }

    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
    }

    private var primaryButtonTitle: String {
        selectedTab == .login ? "Continue" : "Create Account"
    }

    private var canSubmit: Bool {
        !authManager.isLoading &&
        !email.isEmpty &&
        !password.isEmpty &&
        (selectedTab == .login || !confirmPassword.isEmpty)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    heroSection

                    HUDCard {
                        VStack(spacing: 22) {
                            authSwitcher
                            formSection
                            messageSection
                            actionSection
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .hudScreen()
        .onChange(of: selectedTab) {
            email = ""
            password = ""
            confirmPassword = ""
            preferredSourceLanguageCode = "es"
            authManager.errorMessage = ""
            authManager.statusMessage = ""
        }
        .onSubmit {
            switch focusedField {
            case .email:
                focusedField = .password
            case .password where selectedTab == .signup:
                focusedField = .confirmPassword
            default:
                submitCredentials()
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.white.opacity(0.78))
                        .frame(width: 84, height: 84)
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(HUDTheme.stroke, lineWidth: 1)
                        }

                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("HUDini")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(HUDTheme.ink)

                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authSwitcher: some View {
        HStack(spacing: 10) {
            ForEach(AuthTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? .white : HUDTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            Group {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(HUDTheme.ink)
                                } else {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.white.opacity(0.7))
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Email") {
                placeholderTextField(
                    text: $email,
                    placeholder: "you@example.com",
                    focus: .email,
                    submitLabel: .next,
                    textContentType: selectedTab == .login ? .emailAddress : .username,
                    keyboardType: .emailAddress
                )
            }

            field("Password") {
                placeholderSecureField(
                    text: $password,
                    placeholder: "Enter password",
                    focus: .password,
                    submitLabel: selectedTab == .login ? .go : .next
                )
            }

            if selectedTab == .signup {
                field("Confirm Password") {
                    placeholderSecureField(
                        text: $confirmPassword,
                        placeholder: "Re-enter password",
                        focus: .confirmPassword,
                        submitLabel: .go
                    )
                }

                field("Primary Listening Language") {
                    Picker("Language to Translate from", selection: $preferredSourceLanguageCode) {
                        ForEach(TranslationLanguages.sourceOptions) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .tint(HUDTheme.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !authManager.errorMessage.isEmpty {
                messageRow(
                    text: authManager.errorMessage,
                    tint: HUDTheme.rose,
                    icon: "exclamationmark.triangle.fill"
                )
            }

            if !authManager.statusMessage.isEmpty {
                messageRow(
                    text: authManager.statusMessage,
                    tint: HUDTheme.mint,
                    icon: "checkmark.circle.fill"
                )
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: 16) {
            Button(action: submitCredentials) {
                HStack(spacing: 10) {
                    if authManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: selectedTab == .login ? "arrow.right" : "person.crop.circle.badge.plus")
                            .font(.system(size: 15, weight: .bold))
                    }

                    Text(primaryButtonTitle)
                }
            }
            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.ink))
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.7)

            HStack {
                Rectangle().fill(HUDTheme.strokeStrong.opacity(0.4)).frame(height: 1)
                Text("OR")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.inkMuted)
                    .padding(.horizontal, 4)
                Rectangle().fill(HUDTheme.strokeStrong.opacity(0.4)).frame(height: 1)
            }

            Button(action: signInWithGoogle) {
                HStack(spacing: 14) {
                    GoogleLogoMark()
                        .frame(width: 22, height: 22)
                    Text("Continue with Google")
                }
            }
            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.ink))
            .disabled(authManager.isLoading)

            SignInWithAppleButton(.continue) { request in
                authManager.configureSignInWithAppleRequest(request)
            } onCompletion: { result in
                signInWithApple(result: result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(authManager.isLoading)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.inkMuted)
            content()
        }
    }

    private func messageRow(text: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)

            Text(text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(HUDTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func placeholderSecureField(
        text: Binding<String>,
        placeholder: String,
        focus: Field,
        submitLabel: SubmitLabel
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }

            SecureField("", text: text)
                .focused($focusedField, equals: focus)
                .submitLabel(submitLabel)
                .tint(HUDTheme.ink)
                .foregroundStyle(HUDTheme.ink)
                .hudInputFieldStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.clear.contentShape(Rectangle()))
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            focusedField = focus
        })
    }

    private func placeholderTextField(
        text: Binding<String>,
        placeholder: String,
        focus: Field,
        submitLabel: SubmitLabel,
        textContentType: UITextContentType?,
        keyboardType: UIKeyboardType
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .textContentType(textContentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: focus)
                .submitLabel(submitLabel)
                .textFieldStyle(.plain)
                .tint(HUDTheme.ink)
                .foregroundStyle(HUDTheme.ink)
                .hudInputFieldStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.clear.contentShape(Rectangle()))
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded {
            focusedField = focus
        })
    }

    private func submitCredentials() {
        guard canSubmit else { return }
        Task {
            if selectedTab == .login {
                await authManager.signIn(email: email, password: password)
            } else {
                await authManager.signUp(email: email, password: password, confirmPassword: confirmPassword)
            }
        }
    }

    private func signInWithGoogle() {
        Task {
            await authManager.signInWithGoogle()
        }
    }

    private func signInWithApple(result: Result<ASAuthorization, Error>) {
        Task {
            await authManager.signInWithApple(result: result)
        }
    }
}

private struct GoogleLogoMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            let xOffset = (geometry.size.width - 24 * scale) / 2
            let yOffset = (geometry.size.height - 24 * scale) / 2

            ZStack {
                googleBluePath(scale: scale, xOffset: xOffset, yOffset: yOffset)
                    .fill(Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255))

                googleGreenPath(scale: scale, xOffset: xOffset, yOffset: yOffset)
                    .fill(Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255))

                googleYellowPath(scale: scale, xOffset: xOffset, yOffset: yOffset)
                    .fill(Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255))

                googleRedPath(scale: scale, xOffset: xOffset, yOffset: yOffset)
                    .fill(Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> CGPoint {
        CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
    }

    private func googleBluePath(scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> Path {
        Path { path in
            path.move(to: point(22.56, 12.25, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(22.36, 10.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(22.56, 11.47, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(22.49, 10.72, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(12.0, 10.0, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(12.0, 14.26, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(17.92, 14.26, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(15.71, 17.57, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(17.66, 15.63, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(16.88, 16.79, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(15.71, 20.34, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(19.28, 20.34, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(22.56, 12.25, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(21.36, 18.42, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(22.56, 15.6, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.closeSubpath()
        }
    }

    private func googleGreenPath(scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> Path {
        Path { path in
            path.move(to: point(12.0, 23.0, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(19.28, 20.34, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(14.97, 23.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(17.46, 22.02, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(15.71, 17.57, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(12.0, 18.63, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(14.73, 18.23, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(13.48, 18.63, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addCurve(
                to: point(5.84, 14.1, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(9.14, 18.63, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(6.71, 16.7, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(2.18, 14.1, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(2.18, 16.94, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(12.0, 23.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(3.99, 20.53, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(7.7, 23.0, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.closeSubpath()
        }
    }

    private func googleYellowPath(scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> Path {
        Path { path in
            path.move(to: point(5.84, 14.09, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(5.49, 12.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(5.62, 13.43, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(5.49, 12.73, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addCurve(
                to: point(5.84, 9.91, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(5.49, 11.27, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(5.62, 10.57, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(5.84, 7.07, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(2.18, 7.07, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(1.0, 12.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(1.43, 8.55, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(1.0, 10.22, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addCurve(
                to: point(2.18, 16.93, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(1.0, 13.78, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(1.43, 15.45, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(5.03, 14.71, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addLine(to: point(5.84, 14.09, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.closeSubpath()
        }
    }

    private func googleRedPath(scale: CGFloat, xOffset: CGFloat, yOffset: CGFloat) -> Path {
        Path { path in
            path.move(to: point(12.0, 5.38, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(16.21, 7.02, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(13.62, 5.38, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(15.06, 5.94, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(19.36, 3.87, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(12.0, 1.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(17.45, 2.09, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(14.97, 1.0, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addCurve(
                to: point(2.18, 7.07, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(7.7, 1.0, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(3.99, 3.47, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.addLine(to: point(5.84, 9.91, scale: scale, xOffset: xOffset, yOffset: yOffset))
            path.addCurve(
                to: point(12.0, 5.38, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control1: point(6.71, 7.31, scale: scale, xOffset: xOffset, yOffset: yOffset),
                control2: point(9.14, 5.38, scale: scale, xOffset: xOffset, yOffset: yOffset)
            )
            path.closeSubpath()
        }
    }
}

#Preview {
    SignInView()
        .environmentObject(AuthenticationManager())
}
