# Supabase Auth (Apple + Google)

The iOS app signs into the same Supabase project with Apple or Google.

## 1. Keys in the app

Copy values into `sync/SupabaseKeys.swift` (see `SupabaseKeys.example.swift`):

- **URL** — Project Settings → API → Project URL  
- **anon key** — Project Settings → API → `anon` `public`

If both are empty:

- Apple stays local-only (device session)
- Google stays disabled until keys are set

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

Authentication → URL Configuration → Redirect URLs:

- `synchronous://auth`
- `synchronous://**`

The app uses `synchronous://auth` for the Google OAuth callback (`Info.plist` already registers the `synchronous` URL scheme).

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
