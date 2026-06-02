-- Community interaction foundation: likes, cloud saves, and unique downloads.

alter table public.public_study_sets
  add column if not exists like_count integer not null default 0,
  add column if not exists save_count integer not null default 0;

create table if not exists public.community_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  public_set_id uuid not null references public.public_study_sets(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, public_set_id)
);

create table if not exists public.community_saves (
  user_id uuid not null references auth.users(id) on delete cascade,
  public_set_id uuid not null references public.public_study_sets(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, public_set_id)
);

create table if not exists public.community_downloads (
  user_id uuid not null references auth.users(id) on delete cascade,
  public_set_id uuid not null references public.public_study_sets(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, public_set_id)
);

create index if not exists idx_community_likes_public_set
  on public.community_likes(public_set_id);
create index if not exists idx_community_saves_public_set
  on public.community_saves(public_set_id);
create index if not exists idx_community_downloads_public_set
  on public.community_downloads(public_set_id);
create index if not exists idx_public_study_sets_engagement
  on public.public_study_sets(like_count desc, save_count desc, download_count desc, created_at desc);

alter table public.community_likes enable row level security;
alter table public.community_saves enable row level security;
alter table public.community_downloads enable row level security;

grant select, insert, delete on public.community_likes to authenticated;
grant select, insert, delete on public.community_saves to authenticated;
grant select, insert on public.community_downloads to authenticated;

drop policy if exists "Users can read own community likes" on public.community_likes;
create policy "Users can read own community likes"
  on public.community_likes for select
  using (auth.uid() = user_id);

drop policy if exists "Users can manage own community likes" on public.community_likes;
create policy "Users can manage own community likes"
  on public.community_likes for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can read own community saves" on public.community_saves;
create policy "Users can read own community saves"
  on public.community_saves for select
  using (auth.uid() = user_id);

drop policy if exists "Users can manage own community saves" on public.community_saves;
create policy "Users can manage own community saves"
  on public.community_saves for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can read own community downloads" on public.community_downloads;
create policy "Users can read own community downloads"
  on public.community_downloads for select
  using (auth.uid() = user_id);

drop policy if exists "Users can insert own community downloads" on public.community_downloads;
create policy "Users can insert own community downloads"
  on public.community_downloads for insert
  with check (auth.uid() = user_id);

create or replace function public.refresh_public_set_interaction_counts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  affected_set_id uuid;
begin
  affected_set_id := coalesce(new.public_set_id, old.public_set_id);

  update public.public_study_sets
  set
    like_count = (
      select count(*) from public.community_likes
      where public_set_id = affected_set_id
    ),
    save_count = (
      select count(*) from public.community_saves
      where public_set_id = affected_set_id
    )
  where id = affected_set_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_community_likes_refresh_counts on public.community_likes;
create trigger trg_community_likes_refresh_counts
after insert or delete on public.community_likes
for each row execute function public.refresh_public_set_interaction_counts();

drop trigger if exists trg_community_saves_refresh_counts on public.community_saves;
create trigger trg_community_saves_refresh_counts
after insert or delete on public.community_saves
for each row execute function public.refresh_public_set_interaction_counts();

drop trigger if exists trg_community_downloads_refresh_counts on public.community_downloads;
drop function if exists public.increment_public_set_download_count();
create function public.increment_public_set_download_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.public_study_sets
  set download_count = download_count + 1
  where id = new.public_set_id;
  return new;
end;
$$;

create trigger trg_community_downloads_refresh_counts
after insert on public.community_downloads
for each row execute function public.increment_public_set_download_count();

create or replace function public.record_community_download(set_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return;
  end if;

  insert into public.community_downloads (user_id, public_set_id)
  values (auth.uid(), set_id)
  on conflict (user_id, public_set_id) do nothing;
end;
$$;

revoke all on function public.record_community_download(uuid) from public;
grant execute on function public.record_community_download(uuid) to authenticated;
revoke all on function public.increment_download_count(uuid) from public;

-- Backfill counters for projects that already have interaction rows.
update public.public_study_sets sets
set
  like_count = (
    select count(*) from public.community_likes likes
    where likes.public_set_id = sets.id
  ),
  save_count = (
    select count(*) from public.community_saves saves
    where saves.public_set_id = sets.id
  );
