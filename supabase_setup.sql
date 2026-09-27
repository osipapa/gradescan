-- GradeScan: run once in Supabase › SQL Editor › New query › Run.
-- Every row belongs to the signed-in teacher, and row-level security hides it from everyone else.
-- Set up with an earlier version? Run supabase_upgrade_v2.sql instead.

create table if not exists public.quizzes (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null,
  num_questions int not null check (num_questions between 1 and 50),
  num_choices int not null default 4 check (num_choices between 2 and 5),
  answer_key text not null,                             -- one letter per question, '*' = everyone gets credit
  points_per_question numeric not null default 1,
  bonus_count int not null default 0,                   -- the last N questions don't count toward the max
  layout jsonb,                                         -- where everything is printed on the answer sheet (written by the portal)
  question_tags jsonb not null default '[]'::jsonb,     -- one topic per question, e.g. "Grammar"; '' = none
  code text,                                            -- number printed on the sheet, so the phone knows the test
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  period int check (period between 1 and 9),
  created_at timestamptz not null default now()
);

create table if not exists public.scans (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  quiz_id uuid not null references public.quizzes (id) on delete cascade,
  student_id uuid references public.students (id) on delete set null,
  period int check (period between 1 and 9),            -- bubbled on the sheet; null if not marked
  student_name text,                                    -- read from the handwriting on the phone; editable in the portal
  name_image text,                                      -- JPEG data URL of the handwritten name
  sheet_image text,                                     -- JPEG data URL of the scanned sheet with the marks drawn on
  answers text not null,                                -- one char per question: A–E, '-' blank, '*' more than one
  score_override numeric,                               -- set in the portal to replace the computed score
  student_code text,                                    -- unused; kept so older installs match
  scanned_at timestamptz not null default now()
);
create index if not exists scans_quiz_id_idx on public.scans (quiz_id);

alter table public.quizzes  enable row level security;
alter table public.students enable row level security;
alter table public.scans    enable row level security;

create policy "owner only" on public.quizzes  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "owner only" on public.students for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "owner only" on public.scans    for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());

revoke all on public.quizzes, public.students, public.scans from anon;
grant select, insert, update, delete on public.quizzes, public.students, public.scans to authenticated;

-- Student numbers (printed on named sheets), assigned automatically.
alter table public.students add column if not exists number int check (number between 1 and 4095);
create unique index if not exists students_owner_number_key on public.students (owner, number);
create or replace function public.students_next_number() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.number is null then
    select coalesce(max(number), 0) + 1 into new.number from public.students where owner = new.owner;
  end if;
  return new;
end $$;
drop trigger if exists students_number on public.students;
create trigger students_number before insert on public.students for each row execute function public.students_next_number();

-- One scan per student per test: a rescan replaces the earlier one.
alter table public.scans add column if not exists photo_path text;   -- marked photo in the "sheets" storage bucket
alter table public.scans drop constraint if exists scans_quiz_student_key;
alter table public.scans add constraint scans_quiz_student_key unique (quiz_id, student_id);

-- Private storage for the marked photo of every scanned sheet, kept for the record.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sheets', 'sheets', false, 5242880, array['image/jpeg']) on conflict (id) do nothing;
create policy "sheets: own folder read" on storage.objects for select to authenticated
  using (bucket_id = 'sheets' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "sheets: own folder write" on storage.objects for insert to authenticated
  with check (bucket_id = 'sheets' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "sheets: own folder delete" on storage.objects for delete to authenticated
  using (bucket_id = 'sheets' and (storage.foldername(name))[1] = auth.uid()::text);

-- Rows the phone couldn't call, waiting for (or settled by) the teacher: {"7": {"flag": "*", "marks": "AC", "result": null}}
alter table public.scans add column if not exists review jsonb;

-- Which answer sheet a scan was read from: null = the test's own GradeScan sheet, 'zipgrade20' = ZipGrade's 20-question form.
alter table public.scans add column if not exists form text;
