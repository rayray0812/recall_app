-- Community Phase 4: moderation queue, auto-hide, and comment safety checks.

alter table public.public_study_sets
  add column if not exists visibility text not null default 'public'
    check (visibility in ('public', 'hidden')),
  add column if not exists moderation_status text not null default 'approved'
    check (moderation_status in ('approved', 'pending', 'rejected')),
  add column if not exists moderation_reason text not null default '',
  add column if not exists moderated_at timestamptz null;

alter table public.community_comments
  add column if not exists moderation_status text not null default 'approved'
    check (moderation_status in ('approved', 'pending', 'rejected')),
  add column if not exists moderation_reason text not null default '';

alter table public.community_reports
  add column if not exists resolution text not null default '',
  add constraint community_reports_status_check
    check (status in ('pending', 'reviewed', 'dismissed'));

create index if not exists idx_public_study_sets_visibility
  on public.public_study_sets(visibility, created_at desc);
create index if not exists idx_community_reports_queue
  on public.community_reports(status, created_at desc);

create or replace function public.guard_public_set_moderation_fields()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.visibility := 'public';
    new.moderation_status := 'approved';
    new.moderation_reason := '';
    new.moderated_at := null;
    return new;
  end if;

  if (
    new.visibility <> old.visibility
    or new.moderation_status <> old.moderation_status
    or new.moderation_reason <> old.moderation_reason
    or new.moderated_at is distinct from old.moderated_at
  ) and not public.is_global_admin(auth.uid())
    and coalesce(current_setting('app.community_moderation_write', true), '') <> 'on'
  then
    raise exception 'Only moderation workflows can change moderation fields';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_public_study_sets_guard_moderation
  on public.public_study_sets;
create trigger trg_public_study_sets_guard_moderation
before insert or update on public.public_study_sets
for each row execute function public.guard_public_set_moderation_fields();

drop policy if exists "Anyone can read public study sets"
  on public.public_study_sets;
create policy "Visible public study sets are readable"
  on public.public_study_sets for select
  using (
    visibility = 'public'
    or auth.uid() = user_id
    or public.is_global_admin(auth.uid())
  );

create or replace function public.contains_community_sensitive_term(body text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select lower(coalesce(body, '')) ~
    '(色情|裸照|約炮|自殺|殺人|毒品|賭博|仇恨|porn|nude|suicide|kill yourself|drug dealer|gambling)';
$$;

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
  new.created_at := now();
  new.updated_at := now();

  if public.contains_community_sensitive_term(new.body) then
    new.is_hidden := true;
    new.moderation_status := 'pending';
    new.moderation_reason := 'sensitive_term_match';
  else
    new.is_hidden := false;
    new.moderation_status := 'approved';
    new.moderation_reason := '';
  end if;
  return new;
end;
$$;

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

  if not public.is_global_admin(auth.uid()) and (
    new.moderation_status <> old.moderation_status
    or new.moderation_reason <> old.moderation_reason
    or (old.moderation_status <> 'approved' and not new.is_hidden)
  ) then
    raise exception 'Only moderators can change comment moderation fields';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.normalize_community_report_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.reporter_id := auth.uid();
  new.status := 'pending';
  new.resolution := '';
  new.reviewed_by := null;
  new.reviewed_at := null;
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists trg_community_reports_normalize_insert
  on public.community_reports;
create trigger trg_community_reports_normalize_insert
before insert on public.community_reports
for each row execute function public.normalize_community_report_insert();

create or replace function public.auto_hide_reported_public_set()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pending_count integer;
begin
  select count(*)
  into pending_count
  from public.community_reports
  where public_set_id = new.public_set_id
    and status = 'pending';

  if pending_count >= 3 then
    perform set_config('app.community_moderation_write', 'on', true);
    update public.public_study_sets
    set visibility = 'hidden',
        moderation_status = 'pending',
        moderation_reason = 'auto_hidden_after_reports',
        moderated_at = now()
    where id = new.public_set_id
      and visibility = 'public';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_community_reports_auto_hide
  on public.community_reports;
create trigger trg_community_reports_auto_hide
after insert on public.community_reports
for each row execute function public.auto_hide_reported_public_set();

create or replace function public.admin_list_community_reports()
returns table (
  public_set_id uuid,
  title text,
  author_name text,
  visibility text,
  moderation_status text,
  moderation_reason text,
  pending_report_count bigint,
  latest_report_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_global_admin(auth.uid()) then
    raise exception 'Only global admin can list community reports';
  end if;

  return query
  select
    sets.id,
    sets.title,
    sets.author_name,
    sets.visibility,
    sets.moderation_status,
    sets.moderation_reason,
    count(*) filter (where reports.status = 'pending'),
    max(reports.created_at)
  from public.public_study_sets sets
  join public.community_reports reports on reports.public_set_id = sets.id
  group by sets.id
  order by max(reports.created_at) desc;
end;
$$;

create or replace function public.admin_resolve_community_reports(
  target_set_id uuid,
  resolution_action text,
  reason text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  owner_id uuid;
begin
  if not public.is_global_admin(actor_id) then
    raise exception 'Only global admin can resolve community reports';
  end if;
  if resolution_action not in ('restore', 'hide', 'reject') then
    raise exception 'Unsupported moderation action';
  end if;

  update public.public_study_sets
  set visibility = case when resolution_action = 'restore' then 'public' else 'hidden' end,
      moderation_status = case
        when resolution_action = 'restore' then 'approved'
        when resolution_action = 'reject' then 'rejected'
        else 'pending'
      end,
      moderation_reason = coalesce(nullif(trim(reason), ''), resolution_action),
      moderated_at = now()
  where id = target_set_id
  returning user_id into owner_id;

  update public.community_reports
  set status = case when resolution_action = 'restore' then 'dismissed' else 'reviewed' end,
      resolution = resolution_action,
      reviewed_by = actor_id,
      reviewed_at = now()
  where public_set_id = target_set_id
    and status = 'pending';

  insert into public.admin_audit_logs(
    actor_user_id, target_user_id, action, reason, metadata
  ) values (
    actor_id,
    owner_id,
    'community_reports_' || resolution_action,
    coalesce(nullif(trim(reason), ''), resolution_action),
    jsonb_build_object('public_set_id', target_set_id)
  );
end;
$$;

revoke all on function public.admin_list_community_reports() from public, anon;
revoke all on function public.admin_resolve_community_reports(uuid, text, text)
  from public, anon;
grant execute on function public.admin_list_community_reports()
  to authenticated;
grant execute on function public.admin_resolve_community_reports(uuid, text, text)
  to authenticated;
