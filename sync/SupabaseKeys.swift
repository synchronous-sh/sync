import Foundation

/// Fill these from Supabase → Project Settings → API.
/// Leave empty to keep local-only Sign in with Apple (no cloud session).
enum SupabaseKeys {
    /// e.g. https://abcdefghijk.supabase.co
    static let url = ""
    /// `anon` `public` key — never the service-role key.
    static let anonKey = ""
}
