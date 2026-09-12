# Supabase Auth (Sign in with Apple)

The iOS app exchanges Apple’s identity token for a Supabase session.

## 1. Keys in the app

Copy values into `sync/SupabaseKeys.swift` (see `SupabaseKeys.example.swift`):

- **URL** — Project Settings → API → Project URL  
- **anon key** — Project Settings → API → `anon` `public`

If both are empty, Sign in with Apple stays local-only (current device session).

## 2. Enable Apple on the Supabase project

1. Authentication → Providers → **Apple** → enable  
2. **Client IDs**: add the iOS bundle id  
   `sh.synchronous.sync`  
3. For native-only Sign in with Apple you typically do **not** need a secret.  
   If Supabase asks for a secret, create a Services ID + key in Apple Developer and paste them.

## 3. Redirect URLs (dashboard)

Add:

- `synchronous://auth`
- `synchronous://**`

`supabase/config.toml` already uses `synchronous://auth` for local CLI.

## 4. Schema

Apply `supabase/migrations/20260912200000_sync_library_backend.sql` so `profiles` auto-creates on `auth.users` insert.

```bash
npx supabase link --project-ref <friend-project-ref>
npx supabase db push
```

## 5. What the app does

1. User taps **Sign in with Apple**  
2. App receives `identityToken` (+ optional nonce)  
3. `POST /auth/v1/token?grant_type=id_token` with `provider=apple`  
4. Session (access + refresh) is stored in Keychain  
5. `AccountSession.userIDKey` is set to the Supabase user UUID  
6. Sign out calls `/auth/v1/logout` and clears Keychain + local profile keys
