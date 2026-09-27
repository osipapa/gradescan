-- GradeScan: run once in Supabase → SQL Editor → New query → Run.
-- Every row belongs to the signed-in user, and row-level security hides it from everyone else.
-- Student names are encrypted in the browser before they reach this database (students.name_enc).

create table if not exists public.quizzes (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  code text not null,                                   -- 6-char code printed in the sheet's QR codes
  title text not null,
  num_questions int not null check (num_questions between 1 and 50),
  num_choices int not null default 4 check (num_choices between 2 and 5),
  answer_key text not null,                             -- one letter per question, '*' = everyone gets credit
  points_per_question numeric not null default 1,
  bonus_count int not null default 0,                   -- the last N questions don't count toward the max
  created_at timestamptz not null default now(),
  unique (owner, code)
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  period int not null check (period between 1 and 9),
  code text not null,                                   -- 3-digit Student #: period + number, e.g. 914
  name_enc text not null,                               -- AES-GCM ciphertext, never plain text
  created_at timestamptz not null default now(),
  unique (owner, code)
);

create table if not exists public.scans (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  quiz_id uuid not null references public.quizzes (id) on delete cascade,
  student_code text not null,
  answers text not null,                                -- one char per question: A–E, '-' blank, '*' more than one
  score_override numeric,                               -- set in the portal to replace the computed score
  scanned_at timestamptz not null default now(),
  unique (quiz_id, student_code)
);

alter table public.quizzes  enable row level security;
alter table public.students enable row level security;
alter table public.scans    enable row level security;

create policy "owner only" on public.quizzes  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "owner only" on public.students for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "owner only" on public.scans    for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

revoke all on public.quizzes, public.students, public.scans from anon;
grant select, insert, update, delete on public.quizzes, public.students, public.scans to authenticated;
