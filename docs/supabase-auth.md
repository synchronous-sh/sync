# Supabase Auth (Apple + Google)

The iOS app signs into the same Supabase project with Apple or Google.

## 1. Keys in the app

Edit `sync/SupabaseKeys.swift`:

```swift
enum SupabaseKeys {
    static let url = "https://YOUR_PROJECT.supabase.co"
    static let anonKey = "your_anon_key"
}
```

- **URL** — Project Settings → API → Project URL  
- **anon key** — Project Settings → API → `anon` `public`

If both are empty:

- Apple stays local-only (device session)
- Google needs keys before it can complete sign-in

## 2. Enable Apple

1. Authentication → Providers → **Apple** → enable  
2. **Client IDs**: add `sh.synchronous.sync`  
3. Native Sign in with Apple usually needs no secret

## 3. Enable Google

1. Authentication → Providers → **Google** → enable  
2. Create OAuth credentials in Google Cloud Console (Web client is fine for Supabase)  
3. Paste **Client ID** + **Client Secret** into Supabase  
4. Add authorized redirect URI from the Supabase Google provider panel  
   (looks like `https://<project-ref>.supabase.co/auth/v1/callback`)

## 4. Redirect URLs (Supabase dashboard)

The Expo / Curious app used scheme **`curious`**. If this Swift app shares that Supabase project and Site URL is still `curious://auth`, Google will open Expo unless the redirect matches an allow-listed URL.

**This app’s OAuth callback is `curious://auth`** (same as Expo) so a shared project works without dashboard changes. `Info.plist` registers both `curious` and `synchronous`.

Authentication → URL Configuration should include:

- **Site URL:** `curious://auth` (existing Expo default) — or switch to `synchronous://auth` when you own the project and update the app constant to match
- **Redirect URLs:**
  - `curious://auth`
  - `curious://**`
  - `synchronous://auth` (optional, for a later cutover)
  - `synchronous://**`

If Google still opens Expo: Site URL / allow list still points at Expo Go (`exp://…`). Add `curious://auth` (and remove or demote the Expo Go Site URL), then retry.

## 5. Schema

Apply `supabase/migrations/20260912200000_sync_library_backend.sql` so `profiles` auto-creates on `auth.users` insert.

```bash
npx supabase link --project-ref <friend-project-ref>
npx supabase db push
```

## 6. What the app does

### Apple
1. Sign in with Apple → `identityToken`  
2. `POST /auth/v1/token?grant_type=id_token` (`provider=apple`)  
3. Session saved in Keychain  

### Google
1. Opens Google via `ASWebAuthenticationSession` (PKCE)  
2. Callback `synchronous://auth?code=…`  
3. `POST /auth/v1/token?grant_type=pkce`  
4. Session saved in Keychain  

### Shared
- `AccountSession.userIDKey` = Supabase user UUID  
- Launch restores/refreshes the Keychain session  
- Sign out calls `/auth/v1/logout` and clears local profile keys
