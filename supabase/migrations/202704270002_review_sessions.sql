-- Phase A: create review_sessions table.
-- Each learning session (srs, quiz, match, speaking, conversation) creates one row.
-- ReviewLog.session_id references this table for analytics linkage.

create table if not exists public.review_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  modality text not null check (modality in ('srs', 'quiz', 'match', 'speaking', 'conversation')),
  started_at timestamptz not null,
  ended_at timestamptz null,
  item_count int not null default 0,
  completed_count int not null default 0,
  score_avg double precision null,
  metadata jsonb null,
  created_at timestamptz not null default now()
);

-- RLS
alter table public.review_sessions enable row level security;

drop policy if exists "Users can manage own sessions" on public.review_sessions;
create policy "Users can manage own sessions"
  on public.review_sessions for all
  using (auth.uid() = user_id);

-- Indexes
create index if not exists idx_review_sessions_user_started
  on public.review_sessions (user_id, started_at desc);

create index if not exists idx_review_sessions_modality
  on public.review_sessions (user_id, modality);

-- FK from review_logs (activate the deferred constraint from previous migration)
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'fk_review_logs_session'
      and conrelid = 'public.review_logs'::regclass
  ) then
    alter table public.review_logs
      add constraint fk_review_logs_session
      foreign key (session_id) references public.review_sessions(id)
      on delete set null;
  end if;
end;
$$;

comment on table public.review_sessions is
  'Groups review events by learning session. Enables session-level analytics without aggregating raw logs.';
comment on column public.review_sessions.modality is
  'Learning mode: srs | quiz | match | speaking | conversation';
comment on column public.review_sessions.score_avg is
  'Average score for modes that produce a score (speaking/conversation, 0-100).';
