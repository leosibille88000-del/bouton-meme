-- MY BOUTON MEME : à coller dans Supabase > SQL Editor, puis Run.
-- Tu peux le relancer sans risque.

-- Admins : les comptes qui peuvent tout modifier et tout supprimer
create table if not exists public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;

-- Les sons
create table if not exists public.sounds (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users on delete cascade,
  owner_name text,
  name text not null check (char_length(name) between 1 and 40),
  hue int not null default 340 check (hue between 0 and 359),
  kind text not null check (kind in ('audio', 'voice')),
  path text,
  duration real,
  text text check (char_length(text) <= 200),
  pitch real default 1,
  rate real default 1,
  created_at timestamptz not null default now()
);
alter table public.sounds enable row level security;

drop policy if exists "lecture pour tous" on public.sounds;
drop policy if exists "creer ses sons" on public.sounds;
drop policy if exists "modifier ses sons" on public.sounds;
drop policy if exists "supprimer ses sons" on public.sounds;

create policy "lecture pour tous" on public.sounds
  for select using (true);
create policy "creer ses sons" on public.sounds
  for insert to authenticated with check (owner = auth.uid());
create policy "modifier ses sons" on public.sounds
  for update to authenticated
  using (owner = auth.uid() or public.is_admin())
  with check (owner = auth.uid() or public.is_admin());
create policy "supprimer ses sons" on public.sounds
  for delete to authenticated using (owner = auth.uid() or public.is_admin());

-- Le créateur et son pseudo sont fixés par le serveur, impossible de les trafiquer
create or replace function public.sounds_stamp() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.owner := auth.uid();
    new.owner_name := (select raw_user_meta_data->>'pseudo' from auth.users where id = auth.uid());
    new.created_at := now();
  else
    new.owner := old.owner;
    new.owner_name := old.owner_name;
    new.created_at := old.created_at;
    new.path := old.path;
  end if;
  return new;
end $$;

drop trigger if exists sounds_stamp on public.sounds;
create trigger sounds_stamp before insert or update on public.sounds
  for each row execute function public.sounds_stamp();

-- Mise à jour en direct quand quelqu'un ajoute un son
do $$ begin
  alter publication supabase_realtime add table public.sounds;
exception when others then null;
end $$;

-- Stockage des fichiers son (3 Mo max, WAV uniquement)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sounds', 'sounds', true, 3145728, array['audio/wav'])
on conflict (id) do update set public = true,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "envoyer ses fichiers" on storage.objects;
drop policy if exists "supprimer ses fichiers" on storage.objects;

create policy "envoyer ses fichiers" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'sounds' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "supprimer ses fichiers" on storage.objects
  for delete to authenticated
  using (bucket_id = 'sounds' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
