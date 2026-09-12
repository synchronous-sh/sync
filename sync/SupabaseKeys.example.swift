import Foundation

/// Copy values into `SupabaseKeys.swift` from the Supabase dashboard
/// (Project Settings → API → Project URL + `anon` `public` key).
enum SupabaseKeys {
    /// e.g. https://abcdefghijk.supabase.co
    static let url = "https://YOUR_PROJECT.supabase.co"
    /// Publishable / anon key — never the service-role key.
    static let anonKey = "your_anon_key"
}
