-- GradeScan v2 upgrade from the first version (encrypted roster + QR codes). Keeps every test and scan.
-- Run once in Supabase › SQL Editor.

alter table public.quizzes alter column code drop not null;          -- now the number printed on the sheet; the portal fills it
alter table public.quizzes add column if not exists layout jsonb;   -- the portal fills it the next time it opens
alter table public.quizzes add column if not exists question_tags jsonb not null default '[]'::jsonb;

-- The old encrypted roster is replaced by a plain class list.
drop table if exists public.students;
create table public.students (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  period int check (period between 1 and 9),
  created_at timestamptz not null default now()
);
alter table public.students enable row level security;
create policy "owner only" on public.students for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
revoke all on public.students from anon;
grant select, insert, update, delete on public.students to authenticated;

alter table public.scans drop constraint if exists scans_quiz_id_student_code_key;
alter table public.scans alter column student_code drop not null;
alter table public.scans add column if not exists student_id uuid references public.students (id) on delete set null;
alter table public.scans add column if not exists period int check (period between 1 and 9);
alter table public.scans add column if not exists student_name text;
alter table public.scans add column if not exists name_image text;
alter table public.scans add column if not exists sheet_image text;
create index if not exists scans_quiz_id_idx on public.scans (quiz_id);
update public.scans set period = left(student_code, 1)::int
  where period is null and student_code ~ '^[1-9][0-9]{2}$';        -- old Student #s started with the period

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

-- Rows the phone couldn't call, waiting for (or settled by) the teacher.
alter table public.scans add column if not exists review jsonb;

-- Which answer sheet a scan was read from: null = the test's own GradeScan sheet, 'zipgrade20' = ZipGrade's 20-question form.
alter table public.scans add column if not exists form text;
