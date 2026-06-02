-- Community Phase 2: comments and 1-5 star ratings.

alter table public.public_study_sets
  add column if not exists average_rating double precision not null default 0,
  add column if not exists rating_count integer not null default 0,
  add column if not exists comment_count integer not null default 0;

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  public_set_id uuid not null references public.public_study_sets(id) on delete cascade,
  author_name text not null default '',
  body text not null check (char_length(trim(body)) between 1 and 1000),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.community_ratings (
  user_id uuid not null references auth.users(id) on delete cascade,
  public_set_id uuid not null references public.public_study_sets(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, public_set_id)
);

create index if not exists idx_community_comments_public_set
  on public.community_comments(public_set_id, created_at);
create index if not exists idx_community_ratings_public_set
  on public.community_ratings(public_set_id);

alter table public.community_comments enable row level security;
alter table public.community_ratings enable row level security;

grant select on public.community_comments to anon, authenticated;
grant insert, update, delete on public.community_comments to authenticated;
grant select on public.community_ratings to anon, authenticated;
grant insert, update, delete on public.community_ratings to authenticated;

create policy "Visible community comments are public"
  on public.community_comments for select
  using (
    not is_hidden
    or auth.uid() = user_id
    or exists (
      select 1 from public.public_study_sets sets
      where sets.id = public_set_id and sets.user_id = auth.uid()
    )
  );

create policy "Users can create own community comments"
  on public.community_comments for insert
  with check (auth.uid() = user_id);

create policy "Users and set owners can update community comments"
  on public.community_comments for update
  using (
    auth.uid() = user_id
    or exists (
      select 1 from public.public_study_sets sets
      where sets.id = public_set_id and sets.user_id = auth.uid()
    )
  );

create policy "Users can delete own community comments"
  on public.community_comments for delete
  using (auth.uid() = user_id);

create policy "Community ratings are public"
  on public.community_ratings for select
  using (true);

create policy "Users can manage own community ratings"
  on public.community_ratings for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create or replace function public.validate_community_comment_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.user_id <> old.user_id
    or new.public_set_id <> old.public_set_id
    or new.author_name <> old.author_name then
    raise exception 'Community comment identity fields cannot be changed';
  end if;

  if auth.uid() <> old.user_id and new.body <> old.body then
    raise exception 'Only the comment author can edit comment text';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_community_comments_validate_update
before update on public.community_comments
for each row execute function public.validate_community_comment_update();

create or replace function public.refresh_public_set_feedback_counts()
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
    average_rating = coalesce((
      select avg(rating)::double precision from public.community_ratings
      where public_set_id = affected_set_id
    ), 0),
    rating_count = (
      select count(*) from public.community_ratings
      where public_set_id = affected_set_id
    ),
    comment_count = (
      select count(*) from public.community_comments
      where public_set_id = affected_set_id and not is_hidden
    )
  where id = affected_set_id;
  return coalesce(new, old);
end;
$$;

create trigger trg_community_comments_refresh_counts
after insert or update or delete on public.community_comments
for each row execute function public.refresh_public_set_feedback_counts();

create trigger trg_community_ratings_refresh_counts
after insert or update or delete on public.community_ratings
for each row execute function public.refresh_public_set_feedback_counts();
