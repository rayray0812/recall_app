-- Community Phase 2 hardening: trusted comment identity and private ratings.

drop policy if exists "Community ratings are public" on public.community_ratings;
drop policy if exists "Users can read own community ratings" on public.community_ratings;
create policy "Users can read own community ratings"
  on public.community_ratings for select
  using (auth.uid() = user_id);

revoke select on public.community_ratings from anon;

create or replace function public.normalize_community_comment_insert()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  caller_id uuid := auth.uid();
  trusted_author_name text;
begin
  if caller_id is null then
    raise exception 'Not authenticated';
  end if;

  select nullif(trim(display_name), '')
  into trusted_author_name
  from public.profiles
  where user_id = caller_id;

  if trusted_author_name is null then
    select nullif(split_part(email, '@', 1), '')
    into trusted_author_name
    from auth.users
    where id = caller_id;
  end if;

  new.user_id := caller_id;
  new.author_name := coalesce(trusted_author_name, 'Learner');
  new.is_hidden := false;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_community_comments_normalize_insert
  on public.community_comments;
create trigger trg_community_comments_normalize_insert
before insert on public.community_comments
for each row execute function public.normalize_community_comment_insert();
