-- Community Phase 3: real friend requests and privacy-preserving leaderboard.

create table if not exists public.community_friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  addressee_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'blocked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_id <> addressee_id)
);

create unique index if not exists idx_community_friendships_pair
  on public.community_friendships (
    least(requester_id, addressee_id),
    greatest(requester_id, addressee_id)
  );

create index if not exists idx_community_friendships_requester_status
  on public.community_friendships(requester_id, status);

create index if not exists idx_community_friendships_addressee_status
  on public.community_friendships(addressee_id, status);

alter table public.community_friendships enable row level security;

grant select, insert, update, delete
  on public.community_friendships to authenticated;

drop policy if exists "Friendship participants can read" on public.community_friendships;
create policy "Friendship participants can read"
  on public.community_friendships for select
  using (auth.uid() in (requester_id, addressee_id));

drop policy if exists "Users can request friendships" on public.community_friendships;
create policy "Users can request friendships"
  on public.community_friendships for insert
  with check (
    auth.uid() = requester_id
    and requester_id <> addressee_id
    and status = 'pending'
  );

drop policy if exists "Friendship participants can update" on public.community_friendships;
create policy "Friendship participants can update"
  on public.community_friendships for update
  using (auth.uid() in (requester_id, addressee_id))
  with check (auth.uid() in (requester_id, addressee_id));

drop policy if exists "Friendship participants can delete" on public.community_friendships;
create policy "Friendship participants can delete"
  on public.community_friendships for delete
  using (auth.uid() in (requester_id, addressee_id));

create or replace function public.validate_community_friendship_write()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Not authenticated';
  end if;

  if tg_op = 'INSERT' then
    new.requester_id := caller_id;
    new.status := 'pending';
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;

  if new.requester_id <> old.requester_id
     or new.addressee_id <> old.addressee_id then
    raise exception 'Friendship participants cannot be changed';
  end if;

  if old.status = 'pending'
     and new.status = 'accepted'
     and caller_id = old.addressee_id then
    new.updated_at := now();
    return new;
  end if;

  if old.status <> 'blocked'
     and new.status = 'blocked'
     and caller_id in (old.requester_id, old.addressee_id) then
    new.updated_at := now();
    return new;
  end if;

  raise exception 'Invalid friendship status transition';
end;
$$;

drop trigger if exists trg_community_friendships_validate_write
  on public.community_friendships;
create trigger trg_community_friendships_validate_write
before insert or update on public.community_friendships
for each row execute function public.validate_community_friendship_write();

create or replace function public.search_community_profiles(
  search_query text,
  result_limit integer default 20
)
returns table (
  user_id uuid,
  display_name text,
  avatar_url text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.user_id,
    coalesce(nullif(trim(p.display_name), ''), 'Learner'),
    coalesce(p.avatar_url, '')
  from public.profiles p
  where auth.uid() is not null
    and p.user_id <> auth.uid()
    and trim(coalesce(search_query, '')) <> ''
    and p.display_name ilike '%' || trim(search_query) || '%'
  order by p.display_name
  limit least(greatest(coalesce(result_limit, 20), 1), 20);
$$;

revoke all on function public.search_community_profiles(text, integer)
  from public, anon;
grant execute on function public.search_community_profiles(text, integer)
  to authenticated;

create or replace function public.get_my_community_friendships()
returns table (
  id uuid,
  requester_id uuid,
  addressee_id uuid,
  status text,
  other_display_name text,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id,
    f.requester_id,
    f.addressee_id,
    f.status,
    coalesce(nullif(trim(p.display_name), ''), 'Learner'),
    f.updated_at
  from public.community_friendships f
  left join public.profiles p on p.user_id = case
    when f.requester_id = auth.uid() then f.addressee_id
    else f.requester_id
  end
  where auth.uid() is not null
    and auth.uid() in (f.requester_id, f.addressee_id)
  order by f.updated_at desc;
$$;

revoke all on function public.get_my_community_friendships()
  from public, anon;
grant execute on function public.get_my_community_friendships()
  to authenticated;

create or replace function public.get_community_friend_leaderboard()
returns table (
  user_id uuid,
  display_name text,
  weekly_minutes bigint,
  review_count bigint,
  is_current_user boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with visible_users as (
    select auth.uid() as user_id
    where auth.uid() is not null
    union
    select case
      when f.requester_id = auth.uid() then f.addressee_id
      else f.requester_id
    end
    from public.community_friendships f
    where f.status = 'accepted'
      and auth.uid() in (f.requester_id, f.addressee_id)
  )
  select
    visible.user_id,
    coalesce(nullif(trim(p.display_name), ''), 'Learner'),
    coalesce(count(r.id), 0) * 2 as weekly_minutes,
    coalesce(count(r.id), 0) as review_count,
    visible.user_id = auth.uid() as is_current_user
  from visible_users visible
  left join public.profiles p on p.user_id = visible.user_id
  left join public.review_logs r
    on r.user_id = visible.user_id
   and r.reviewed_at >= now() - interval '7 days'
  group by visible.user_id, p.display_name
  order by weekly_minutes desc, display_name;
$$;

revoke all on function public.get_community_friend_leaderboard()
  from public, anon;
grant execute on function public.get_community_friend_leaderboard()
  to authenticated;
