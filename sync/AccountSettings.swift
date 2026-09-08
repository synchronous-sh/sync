import SwiftUI
import AuthenticationServices

enum AccountSession {
    static let userIDKey = "appleUserID"
    static let nameKey = "appleDisplayName"
    static let usernameKey = "appleUsername"
    static let bioKey = "appleBio"

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
                Text("Your library lives in iCloud on this Apple ID, including saved videos. Sign in so it follows you when you log out and back in.")
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
