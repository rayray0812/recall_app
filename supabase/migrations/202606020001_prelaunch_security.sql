-- Pre-launch security hardening.
--   1. delete_my_account(): real account deletion (App Store 5.1.1(v) / Play policy).
--   2. search_path pinning on existing security-definer functions.
--   3. profiles read policy so authors' display_name is visible to others.

-- 1. Account self-deletion -------------------------------------------------
-- Removes the auth.users row for the calling user; every app table that
-- references auth.users(id) with ON DELETE CASCADE is cleaned up automatically.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- 2. Harden existing security-definer functions ----------------------------
-- get_user_public_stats was missing `set search_path`, leaving it open to
-- search_path hijacking when invoked as definer.
create or replace function public.get_user_public_stats(target_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  result json;
begin
  select json_build_object(
    'published_count', count(*),
    'total_downloads', coalesce(sum(download_count), 0)
  ) into result
  from public.public_study_sets
  where user_id = target_user_id;
  return result;
end;
$$;

-- increment_download_count is superseded by record_community_download (which
-- records a per-user row), but it still exists as a best-effort fallback. Pin
-- its search_path and keep it revoked from anon/public so it can't be abused to
-- inflate counters anonymously.
create or replace function public.increment_download_count(set_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.public_study_sets
  set download_count = download_count + 1
  where id = set_id;
end;
$$;

revoke all on function public.increment_download_count(uuid) from public, anon;
grant execute on function public.increment_download_count(uuid) to authenticated;

-- 3. profiles read access --------------------------------------------------
-- profiles_self_all only lets a user read their own row, but community and
-- classroom features need to show other users' display_name. profiles holds
-- only display_name + role (non-sensitive), so allow read access to everyone
-- while keeping writes self-only (profiles_self_all still governs INSERT/
-- UPDATE/DELETE).
drop policy if exists "profiles_select_public" on public.profiles;
create policy "profiles_select_public"
on public.profiles
for select
using (true);

grant select on public.profiles to anon, authenticated;
