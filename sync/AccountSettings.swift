import SwiftUI
import AuthenticationServices

enum AccountSession {
    static let userIDKey = "appleUserID"
    static let nameKey = "appleDisplayName"

    static func apply(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        UserDefaults.standard.set(credential.user, forKey: userIDKey)
        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
        if !name.isEmpty {
            UserDefaults.standard.set(name, forKey: nameKey)
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            SyncTheme.paper.ignoresSafeArea()
            Image("BrandLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 128, height: 128)
        }
    }
}

struct SignInView: View {
    var body: some View {
        ZStack {
            SyncTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image("BrandLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .padding(.bottom, 28)
                Text("Sign in to sync")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundStyle(SyncTheme.ink)
                    .multilineTextAlignment(.center)
                Text("Your library lives in iCloud on this Apple ID. Sign in so it can follow you to a new phone.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 28)
                Spacer()
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    if case .success(let authorization) = result {
                        AccountSession.apply(authorization)
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
    }
}

struct AccountSettingsSection: View {
    @AppStorage(AccountSession.nameKey) private var displayName = ""

    var body: some View {
        Section("Account") {
            Text(displayName.isEmpty ? "Signed in with Apple" : displayName)
                .foregroundStyle(SyncTheme.ink)
                .listRowBackground(SyncTheme.paperRaised)
            Text("Saves and collections sync with iCloud. Photos and videos on this phone still stay in the app files until we move those too. For you headlines stay on-device.")
                .font(.system(size: 13))
                .foregroundStyle(SyncTheme.inkMuted)
                .listRowBackground(SyncTheme.paperRaised)
        }
    }
}
