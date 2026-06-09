-- Add AI card auto-fill (cardLookup) to server-side AI metering.
--
-- cardLookup prefers on-device inference, but its cloud fallback runs through
-- ai-proxy with Grasp's provider secrets, so it must be a valid metered task in
-- the daily quota table and the consume function.

alter table public.ai_daily_usage
  drop constraint if exists ai_daily_usage_task_type_check;

alter table public.ai_daily_usage
  add constraint ai_daily_usage_task_type_check
  check (task_type in (
    'exampleSentence',
    'photoImport',
    'conversationTurn',
    'speakingScore',
    'smartDistractors',
    'cardLookup'
  ));

create or replace function public.consume_ai_daily_quota(
  p_user_id uuid,
  p_task_type text,
  p_usage_date date,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    return false;
  end if;

  if p_task_type not in (
    'exampleSentence',
    'photoImport',
    'conversationTurn',
    'speakingScore',
    'smartDistractors',
    'cardLookup'
  ) then
    return false;
  end if;

  if p_limit < 0 then
    insert into public.ai_daily_usage(user_id, usage_date, task_type, used_count)
    values (p_user_id, p_usage_date, p_task_type, 1)
    on conflict (user_id, usage_date, task_type)
    do update set
      used_count = public.ai_daily_usage.used_count + 1,
      updated_at = now();
    return true;
  end if;

  insert into public.ai_daily_usage(user_id, usage_date, task_type, used_count)
  values (p_user_id, p_usage_date, p_task_type, 1)
  on conflict do nothing;

  if found then
    return true;
  end if;

  update public.ai_daily_usage
  set
    used_count = used_count + 1,
    updated_at = now()
  where user_id = p_user_id
    and usage_date = p_usage_date
    and task_type = p_task_type
    and used_count < p_limit;

  return found;
end;
$$;

revoke all on function public.consume_ai_daily_quota(uuid, text, date, integer)
  from public;
grant execute on function public.consume_ai_daily_quota(uuid, text, date, integer)
  to service_role;
