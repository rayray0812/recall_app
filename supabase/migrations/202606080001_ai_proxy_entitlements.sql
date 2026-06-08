-- Server-side AI entitlement, quota, and usage ledger.
--
-- Security intent:
-- - Flutter may read its own entitlement/usage for UI.
-- - Flutter cannot grant plans, insert usage, or reset quota.
-- - Supabase Edge Functions use the service role to consume quota and write
--   usage events after calling provider APIs with server-held secrets.

create table if not exists public.user_ai_entitlements (
  user_id uuid primary key references auth.users(id) on delete cascade,
  tier text not null default 'free'
    check (tier in ('free', 'plus', 'pro_ai', 'classroom')),
  source text not null default 'system'
    check (source in ('system', 'storekit', 'revenuecat', 'admin', 'classroom')),
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ai_daily_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null,
  task_type text not null
    check (task_type in (
      'photoImport',
      'conversationTurn',
      'speakingScore',
      'smartDistractors'
    )),
  used_count integer not null default 0 check (used_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, usage_date, task_type)
);

create table if not exists public.ai_usage_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_type text not null,
  provider text not null,
  model text not null,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  estimated_cost_usd numeric(12, 8) not null default 0 check (estimated_cost_usd >= 0),
  success boolean not null default true,
  failure_reason text,
  created_at timestamptz not null default now()
);

create index if not exists ai_usage_events_user_created_idx
  on public.ai_usage_events(user_id, created_at desc);

create index if not exists ai_daily_usage_user_date_idx
  on public.ai_daily_usage(user_id, usage_date desc);

alter table public.user_ai_entitlements enable row level security;
alter table public.ai_daily_usage enable row level security;
alter table public.ai_usage_events enable row level security;

drop policy if exists "Users can read own AI entitlement"
  on public.user_ai_entitlements;
create policy "Users can read own AI entitlement"
  on public.user_ai_entitlements
  for select
  using (auth.uid() = user_id);

drop policy if exists "Users can read own AI daily usage"
  on public.ai_daily_usage;
create policy "Users can read own AI daily usage"
  on public.ai_daily_usage
  for select
  using (auth.uid() = user_id);

drop policy if exists "Users can read own AI usage events"
  on public.ai_usage_events;
create policy "Users can read own AI usage events"
  on public.ai_usage_events
  for select
  using (auth.uid() = user_id);

-- Keep local plan strings out of security decisions. Edge Functions call this
-- with the service role, so users cannot race or forge their quota consumption.
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
    'photoImport',
    'conversationTurn',
    'speakingScore',
    'smartDistractors'
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
