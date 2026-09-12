import SwiftUI
import AuthenticationServices

enum AccountSession {
    static let userIDKey = "appleUserID"
    static let nameKey = "appleDisplayName"
    static let usernameKey = "appleUsername"
    static let bioKey = "appleBio"
    static let onboardingKey = "hasCompletedOnboarding"

    static func apply(userID: String, fullName: PersonNameComponents?) {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: userIDKey)

        let name = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty {
            UserDefaults.standard.set(name, forKey: nameKey)
        }
    }

    static func apply(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        apply(userID: credential.user, fullName: credential.fullName)
    }

    static func signOut() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: bioKey)
    }

    /// Drops the local session if Apple reports the credential was revoked or deleted.
    static func refreshCredentialState(for userID: String) {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: trimmed) { state, _ in
            switch state {
            case .revoked, .notFound:
                DispatchQueue.main.async { signOut() }
            case .authorized, .transferred:
                break
            @unknown default:
                break
            }
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
    @AppStorage(AccountSession.userIDKey) private var userID = ""
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @State private var errorText: String?
    @State private var isWorking = false

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
                Text("Your library lives in iCloud on this Apple ID, including saved videos. Sign in so it follows you when you log out and back in.")
                    .font(.system(size: 16))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 28)

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .padding(.horizontal, 28)
                }

                Spacer()

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                    isWorking = true
                    errorText = nil
                } onCompletion: { result in
                    isWorking = false
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                            errorText = "Apple didn’t return a usable sign-in. Try again."
                            return
                        }
                        // Write through @AppStorage so RootView leaves this screen immediately.
                        userID = credential.user
                        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        if !name.isEmpty {
                            displayName = name
                        }
                        AccountSession.apply(userID: credential.user, fullName: credential.fullName)
                    case .failure(let error):
                        let ns = error as NSError
                        if ns.domain == ASAuthorizationError.errorDomain,
                           ns.code == ASAuthorizationError.canceled.rawValue {
                            return
                        }
                        errorText = appleErrorMessage(error)
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 28)
                .disabled(isWorking)
                .opacity(isWorking ? 0.7 : 1)
                .padding(.bottom, 40)
            }
        }
    }

    private func appleErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == ASAuthorizationError.errorDomain {
            switch ns.code {
            case ASAuthorizationError.failed.rawValue:
                return "Sign in failed. Check Settings → Apple ID, then try again."
            case ASAuthorizationError.invalidResponse.rawValue:
                return "Apple returned an invalid response. Try again in a moment."
            case ASAuthorizationError.notHandled.rawValue:
                return "Sign in wasn’t handled. Restart the app and try again."
            case ASAuthorizationError.unknown.rawValue:
                return "Couldn’t complete Sign in with Apple. Confirm Sign in with Apple is enabled for this build in the developer portal."
            case ASAuthorizationError.notInteractive.rawValue:
                return "Sign in needs interaction. Unlock your iPhone and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

struct AccountSettingsSection: View {
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @AppStorage(AccountSession.usernameKey) private var username = ""

    var body: some View {
        Section("Account") {
            NavigationLink(value: Route.profile) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(SyncTheme.ink)
                        Text(initial)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(SyncTheme.paper)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName.isEmpty ? "You" : displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SyncTheme.ink)
                        Text(username.isEmpty ? "View profile" : "@\(username)")
                            .font(.system(size: 13))
                            .foregroundStyle(SyncTheme.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(SyncTheme.paperRaised)
        }
    }

    private var initial: String {
        let source = displayName.isEmpty ? "Y" : displayName
        return String(source.prefix(1)).uppercased()
    }
}

struct AccountProfileView: View {
    @AppStorage(AccountSession.nameKey) private var displayName = ""
    @AppStorage(AccountSession.usernameKey) private var username = ""
    @AppStorage(AccountSession.bioKey) private var bio = ""
    @AppStorage(AccountSession.userIDKey) private var userID = ""

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    ZStack {
                        Circle().fill(SyncTheme.ink)
                        Text(initial)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(SyncTheme.paper)
                    }
                    .frame(width: 88, height: 88)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("Profile") {
                TextField("Name", text: $displayName)
                    .textContentType(.name)
                    .foregroundStyle(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .foregroundStyle(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                    .foregroundStyle(SyncTheme.ink)
                    .listRowBackground(SyncTheme.paperRaised)
            }

            Section {
                Text(userID.isEmpty
                     ? "Sign in with Apple from the welcome screen to keep this profile on your Apple ID."
                     : "Signed in with Apple. Saves, collections, and videos sync with iCloud on this Apple ID.")
                    .font(.system(size: 13))
                    .foregroundStyle(SyncTheme.inkMuted)
                    .listRowBackground(SyncTheme.paperRaised)
            }
        }
        .scrollContentBackground(.hidden)
        .syncScreen()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var initial: String {
        let source = displayName.isEmpty ? "Y" : displayName
        return String(source.prefix(1)).uppercased()
    }
}
