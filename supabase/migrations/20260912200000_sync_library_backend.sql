-- synchronous personal library backend.
-- Additive: safe to apply beside an existing Curious/learning schema
-- (users, content, learning_paths, custom_courses, etc.).

create extension if not exists pgcrypto;
create extension if not exists vector;

-- Profiles for sync. Separate from public.users if that table already exists
-- for the learning app; both reference auth.users.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text,
  bio text,
  avatar_path text,
  onboarding_complete boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_len check (username is null or char_length(username) between 2 and 40)
);

create table if not exists public.library_saves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null check (source in (
    'tiktok','instagram','youtube','x','reddit','github','spotify','web','screenshot','note'
  )),
  source_url text not null default '',
  canonical_url text not null default '',
  content_type text not null check (content_type in (
    'video','post','article','repository','image','text','product','place','music'
  )),
  title text not null default 'Saved item',
  summary text not null default '',
  creator_name text not null default '',
  creator_handle text not null default '',
  raw_text text not null default '',
  topics text[] not null default '{}',
  entities text[] not null default '{}',
  processing text not null default 'saved' check (processing in ('saved','processing','ready','failed')),
  image_path text not null default '',
  media_path text not null default '',
  slide_paths text[] not null default '{}',
  client_id uuid,
  saved_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint library_saves_title_len check (char_length(title) between 1 and 500),
  constraint library_saves_url_len check (char_length(source_url) <= 4000 and char_length(canonical_url) <= 4000)
);

create unique index if not exists library_saves_user_client_id_uidx
  on public.library_saves (user_id, client_id)
  where client_id is not null;

create unique index if not exists library_saves_user_canonical_uidx
  on public.library_saves (user_id, canonical_url)
  where canonical_url <> '';

create index if not exists library_saves_user_saved_at_idx
  on public.library_saves (user_id, saved_at desc);

create index if not exists library_saves_topics_gin
  on public.library_saves using gin (topics);

create table if not exists public.library_collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  is_pinned boolean not null default false,
  client_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists library_collections_user_client_id_uidx
  on public.library_collections (user_id, client_id)
  where client_id is not null;

create unique index if not exists library_collections_user_name_uidx
  on public.library_collections (user_id, lower(name));

create table if not exists public.library_collection_saves (
  collection_id uuid not null references public.library_collections(id) on delete cascade,
  save_id uuid not null references public.library_saves(id) on delete cascade,
  position integer not null default 0,
  added_at timestamptz not null default now(),
  primary key (collection_id, save_id)
);

create index if not exists library_collection_saves_save_idx
  on public.library_collection_saves (save_id);

-- OpenAI text-embedding-3-small = 1536 dims. Local NLEmbedding can land later
-- as a separate column/model once we standardize remote embeddings.
create table if not exists public.library_save_embeddings (
  save_id uuid primary key references public.library_saves(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  model text not null default 'text-embedding-3-small',
  embedding vector(1536) not null,
  updated_at timestamptz not null default now()
);

create index if not exists library_save_embeddings_user_idx
  on public.library_save_embeddings (user_id);

create index if not exists library_save_embeddings_hnsw
  on public.library_save_embeddings
  using hnsw (embedding vector_cosine_ops);

-- Shared AI rate-limit log. Create only if the learning app has not already.
create table if not exists public.ai_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  input_units integer not null default 0 check (input_units >= 0),
  created_at timestamptz not null default now()
);

create index if not exists ai_requests_user_created_idx
  on public.ai_requests (user_id, created_at desc);

-- Keyword search helper for hybrid retrieval (PRODUCT §4).
create or replace function public.library_saves_search(query text, result_limit integer default 40)
returns setof public.library_saves
language sql
stable
security invoker
set search_path = public
as $$
  select *
  from public.library_saves s
  where s.user_id = (select auth.uid())
    and (
      query is null
      or length(trim(query)) = 0
      or to_tsvector(
        'english',
        coalesce(s.title, '') || ' ' ||
        coalesce(s.summary, '') || ' ' ||
        coalesce(s.raw_text, '') || ' ' ||
        coalesce(s.creator_name, '') || ' ' ||
        coalesce(array_to_string(s.topics, ' '), '') || ' ' ||
        coalesce(array_to_string(s.entities, ' '), '')
      ) @@ plainto_tsquery('english', query)
      or s.title ilike '%' || query || '%'
      or s.summary ilike '%' || query || '%'
    )
  order by s.saved_at desc
  limit greatest(1, least(coalesce(result_limit, 40), 100));
$$;

create or replace function public.match_library_saves(
  query_embedding vector(1536),
  match_count integer default 20,
  min_similarity float default 0.2
)
returns table (
  save_id uuid,
  similarity float
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    e.save_id,
    (1 - (e.embedding <=> query_embedding))::float as similarity
  from public.library_save_embeddings e
  where e.user_id = (select auth.uid())
    and (1 - (e.embedding <=> query_embedding)) >= min_similarity
  order by e.embedding <=> query_embedding
  limit greatest(1, least(coalesce(match_count, 20), 50));
$$;

create or replace function public.handle_new_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id, display_name)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), 'Learner')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.handle_new_profile();

insert into storage.buckets(id, name, public)
values ('library-media', 'library-media', false)
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.library_saves enable row level security;
alter table public.library_collections enable row level security;
alter table public.library_collection_saves enable row level security;
alter table public.library_save_embeddings enable row level security;
alter table public.ai_requests enable row level security;

drop policy if exists "own profile select" on public.profiles;
drop policy if exists "own profile update" on public.profiles;
drop policy if exists "own profile insert" on public.profiles;
create policy "own profile select" on public.profiles for select to authenticated
  using ((select auth.uid()) = id);
create policy "own profile update" on public.profiles for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create policy "own profile insert" on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);

drop policy if exists "own library saves" on public.library_saves;
create policy "own library saves" on public.library_saves for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "own library collections" on public.library_collections;
create policy "own library collections" on public.library_collections for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "own library collection saves" on public.library_collection_saves;
create policy "own library collection saves" on public.library_collection_saves for all to authenticated
  using (
    exists (
      select 1 from public.library_collections c
      where c.id = collection_id and c.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.library_collections c
      where c.id = collection_id and c.user_id = (select auth.uid())
    )
    and exists (
      select 1 from public.library_saves s
      where s.id = save_id and s.user_id = (select auth.uid())
    )
  );

drop policy if exists "own library embeddings" on public.library_save_embeddings;
create policy "own library embeddings" on public.library_save_embeddings for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "own ai requests select" on public.ai_requests;
drop policy if exists "own ai requests insert" on public.ai_requests;
create policy "own ai requests select" on public.ai_requests for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "own ai requests insert" on public.ai_requests for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "library media owner read" on storage.objects;
drop policy if exists "library media owner write" on storage.objects;
drop policy if exists "library media owner update" on storage.objects;
drop policy if exists "library media owner delete" on storage.objects;
create policy "library media owner read" on storage.objects for select to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "library media owner write" on storage.objects for insert to authenticated
  with check (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "library media owner update" on storage.objects for update to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid()::text))
  with check (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "library media owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid()::text));

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.library_saves to authenticated;
grant select, insert, update, delete on public.library_collections to authenticated;
grant select, insert, update, delete on public.library_collection_saves to authenticated;
grant select, insert, update, delete on public.library_save_embeddings to authenticated;
grant select, insert on public.ai_requests to authenticated;
grant usage, select on sequence public.ai_requests_id_seq to authenticated;
grant execute on function public.library_saves_search(text, integer) to authenticated;
grant execute on function public.match_library_saves(vector, integer, float) to authenticated;

revoke execute on function public.handle_new_profile() from public, anon, authenticated;
