-- =====================================================================
-- SHK Pro – Datenbank-Einrichtung (einmalig im Supabase SQL Editor ausführen)
-- Rollen: Chef ("boss") und Arbeiter ("worker"), getrennt nach Betrieb.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tabellen ----------
create table if not exists public.companies (
  "id" uuid primary key default gen_random_uuid(),
  "name" text not null default '',
  "inviteCode" text not null unique,
  "workdayStart" int not null default 7,
  "workdayEnd" int not null default 17,
  "defaultDuration" int not null default 60,
  "createdAt" timestamptz not null default now()
);

create table if not exists public.profiles (
  "id" uuid primary key references auth.users(id) on delete cascade,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "accountRole" text not null check ("accountRole" in ('boss', 'worker')),
  "name" text not null default '',
  "role" text not null default '',
  "phone" text not null default '',
  "colorHex" text not null default '#17607A',
  "isActive" boolean not null default true,
  "acceptedTermsAt" timestamptz,
  "createdAt" timestamptz not null default now()
);

create table if not exists public.customers (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "firstName" text not null default '', "lastName" text not null default '', "company" text not null default '',
  "phone" text not null default '', "email" text not null default '', "street" text not null default '',
  "postalCode" text not null default '', "city" text not null default '', "notes" text not null default '',
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now()
);

create table if not exists public.buildings (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "customerId" uuid not null references public.customers(id) on delete cascade,
  "name" text not null default '', "type" text not null default 'singleFamily', "street" text not null default '',
  "postalCode" text not null default '', "city" text not null default '', "heatingSystem" text not null default '',
  "constructionYear" text not null default '', "notes" text not null default '',
  "createdAt" timestamptz not null default now()
);

create table if not exists public.jobs (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "number" int not null default 0,
  "title" text not null default '', "details" text not null default '',
  "status" text not null default 'new', "priority" text not null default 'normal',
  "customerId" uuid references public.customers(id) on delete cascade,
  "buildingId" uuid references public.buildings(id) on delete set null,
  "assigneeId" uuid references public.profiles(id) on delete set null,
  "startDate" timestamptz, "dueDate" timestamptz,
  "internalNotes" text not null default '',
  "createdAt" timestamptz not null default now(), "updatedAt" timestamptz not null default now(),
  "completedAt" timestamptz
);

create table if not exists public.appointments (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "title" text not null default '', "start" timestamptz not null, "end" timestamptz not null,
  "location" text not null default '', "notes" text not null default '',
  "employeeId" uuid references public.profiles(id) on delete set null,
  "jobId" uuid references public.jobs(id) on delete cascade,
  "createdAt" timestamptz not null default now()
);

create table if not exists public.time_entries (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "jobId" uuid not null references public.jobs(id) on delete cascade,
  "employeeId" uuid references public.profiles(id) on delete set null,
  "start" timestamptz not null, "end" timestamptz,
  "breakMinutes" int not null default 0, "note" text not null default '',
  "createdAt" timestamptz not null default now()
);

create table if not exists public.materials (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "jobId" uuid not null references public.jobs(id) on delete cascade,
  "name" text not null default '', "articleNumber" text not null default '',
  "quantity" double precision not null default 1, "unit" text not null default 'Stk.',
  "unitPrice" double precision,
  "createdAt" timestamptz not null default now()
);

create table if not exists public.photos (
  "id" uuid primary key,
  "companyId" uuid not null references public.companies(id) on delete cascade,
  "jobId" uuid not null references public.jobs(id) on delete cascade,
  "path" text not null, "size" int not null default 0,
  "isCompletion" boolean not null default false, "note" text not null default '',
  "createdBy" uuid default auth.uid(),
  "createdAt" timestamptz not null default now()
);

-- ---------- Hilfsfunktionen (umgehen RLS gezielt, nur lesend) ----------
create or replace function public.my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select "companyId" from public.profiles where "id" = auth.uid() and "isActive"
$$;

create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where "id" = auth.uid() and "accountRole" = 'boss' and "isActive")
$$;

-- Auftrag sichtbar: Chef sieht alles im Betrieb, Arbeiter nur zugewiesene oder eingeplante Aufträge
create or replace function public.job_visible(j uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.jobs jb
    where jb."id" = j and jb."companyId" = public.my_company()
      and (public.is_boss() or jb."assigneeId" = auth.uid()
           or exists (select 1 from public.appointments a where a."jobId" = jb."id" and a."employeeId" = auth.uid()))
  )
$$;

create or replace function public.customer_visible(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.customers cu where cu."id" = c and cu."companyId" = public.my_company())
     and (public.is_boss() or exists (select 1 from public.jobs jb where jb."customerId" = c and public.job_visible(jb."id")))
$$;

-- ---------- Registrierung ----------
create or replace function public.create_company(company_name text, user_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if exists (select 1 from public.profiles where "id" = auth.uid()) then raise exception 'Dieses Konto gehört bereits zu einem Betrieb'; end if;
  insert into public.companies ("name", "inviteCode")
    values (trim(company_name), upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)))
    returning "id" into cid;
  insert into public.profiles ("id", "companyId", "accountRole", "name", "acceptedTermsAt")
    values (auth.uid(), cid, 'boss', trim(user_name), now());
  return cid;
end $$;

create or replace function public.join_company(code text, user_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid; n int;
  palette text[] := array['#2F64A0','#2B7F52','#B86E0B','#7D4E99','#BF3B30','#4F6272','#8C6D1F','#2E7D7A','#A34B76','#17607A'];
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if exists (select 1 from public.profiles where "id" = auth.uid()) then raise exception 'Dieses Konto gehört bereits zu einem Betrieb'; end if;
  select "id" into cid from public.companies where "inviteCode" = upper(trim(code));
  if cid is null then raise exception 'Einladungscode ist ungültig'; end if;
  select count(*) into n from public.profiles where "companyId" = cid;
  insert into public.profiles ("id", "companyId", "accountRole", "name", "colorHex", "acceptedTermsAt")
    values (auth.uid(), cid, 'worker', trim(user_name), palette[(n % 10) + 1], now());
  return cid;
end $$;

create or replace function public.new_invite_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
begin
  if not public.is_boss() then raise exception 'Nur der Chef darf den Code ändern'; end if;
  update public.companies set "inviteCode" = c where "id" = public.my_company();
  return c;
end $$;

-- Konto löschen (DSGVO): Arbeiter löscht sein Konto; Chef löscht Betrieb samt allen Daten und sein Konto
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare cid uuid; boss boolean;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  select "companyId", "accountRole" = 'boss' into cid, boss from public.profiles where "id" = auth.uid();
  if boss then delete from public.companies where "id" = cid; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------- Schutzregeln (Trigger) ----------
-- Arbeiter dürfen bei Aufträgen nur Status und Notizen ändern
create or replace function public.jobs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and not public.is_boss() then
    if (new."title", new."details", new."customerId", new."buildingId", new."assigneeId", new."priority",
        new."startDate", new."dueDate", new."number", new."companyId")
       is distinct from
       (old."title", old."details", old."customerId", old."buildingId", old."assigneeId", old."priority",
        old."startDate", old."dueDate", old."number", old."companyId") then
      raise exception 'Nur der Chef darf diese Angaben ändern.';
    end if;
  end if;
  -- Abschluss nur mit Abschlussfoto
  if new."status" = 'completed' and (tg_op = 'INSERT' or old."status" is distinct from 'completed') then
    if not exists (select 1 from public.photos p where p."jobId" = new."id" and p."isCompletion") then
      raise exception 'Abschlussfoto fehlt: Ein Auftrag kann nur mit Foto der erledigten Arbeit abgeschlossen werden.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_guard on public.jobs;
create trigger jobs_guard before insert or update on public.jobs for each row execute function public.jobs_guard();

-- Rolle und Betrieb sind unveränderlich; Arbeiter dürfen sich nicht selbst (de)aktivieren
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new."accountRole" is distinct from old."accountRole" or new."companyId" is distinct from old."companyId" then
    raise exception 'Rolle und Betrieb können nicht geändert werden.';
  end if;
  if new."isActive" is distinct from old."isActive" and not public.is_boss() then
    raise exception 'Nur der Chef darf Mitarbeiter aktivieren oder deaktivieren.';
  end if;
  if new."id" = auth.uid() and not new."isActive" then
    raise exception 'Sie können sich nicht selbst deaktivieren.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles for each row execute function public.profiles_guard();

-- ---------- Zugriffsregeln (Row Level Security) ----------
alter table public.companies enable row level security;
alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.buildings enable row level security;
alter table public.jobs enable row level security;
alter table public.appointments enable row level security;
alter table public.time_entries enable row level security;
alter table public.materials enable row level security;
alter table public.photos enable row level security;

create policy "companies_select" on public.companies for select to authenticated using ("id" = public.my_company());
create policy "companies_update" on public.companies for update to authenticated using ("id" = public.my_company() and public.is_boss());

create policy "profiles_select" on public.profiles for select to authenticated using ("companyId" = public.my_company() or "id" = auth.uid());
create policy "profiles_update" on public.profiles for update to authenticated
  using ("id" = auth.uid() or ("companyId" = public.my_company() and public.is_boss()));
create policy "profiles_delete" on public.profiles for delete to authenticated
  using ("companyId" = public.my_company() and public.is_boss() and "id" <> auth.uid());

create policy "customers_select" on public.customers for select to authenticated using (public.customer_visible("id"));
create policy "customers_write" on public.customers for all to authenticated
  using ("companyId" = public.my_company() and public.is_boss()) with check ("companyId" = public.my_company() and public.is_boss());

create policy "buildings_select" on public.buildings for select to authenticated using (public.customer_visible("customerId"));
create policy "buildings_write" on public.buildings for all to authenticated
  using ("companyId" = public.my_company() and public.is_boss()) with check ("companyId" = public.my_company() and public.is_boss());

create policy "jobs_select" on public.jobs for select to authenticated using (public.job_visible("id"));
create policy "jobs_insert" on public.jobs for insert to authenticated with check ("companyId" = public.my_company() and public.is_boss());
create policy "jobs_update" on public.jobs for update to authenticated
  using ("companyId" = public.my_company() and (public.is_boss() or "assigneeId" = auth.uid()))
  with check ("companyId" = public.my_company());
create policy "jobs_delete" on public.jobs for delete to authenticated using ("companyId" = public.my_company() and public.is_boss());

create policy "appointments_select" on public.appointments for select to authenticated
  using ("companyId" = public.my_company() and (public.is_boss() or "employeeId" = auth.uid() or public.job_visible("jobId")));
create policy "appointments_write" on public.appointments for all to authenticated
  using ("companyId" = public.my_company() and public.is_boss()) with check ("companyId" = public.my_company() and public.is_boss());

create policy "time_select" on public.time_entries for select to authenticated using (public.job_visible("jobId"));
create policy "time_write" on public.time_entries for all to authenticated
  using (public.job_visible("jobId")) with check ("companyId" = public.my_company() and public.job_visible("jobId"));

create policy "materials_select" on public.materials for select to authenticated using (public.job_visible("jobId"));
create policy "materials_write" on public.materials for all to authenticated
  using (public.job_visible("jobId")) with check ("companyId" = public.my_company() and public.job_visible("jobId"));

create policy "photos_select" on public.photos for select to authenticated using (public.job_visible("jobId"));
create policy "photos_insert" on public.photos for insert to authenticated
  with check ("companyId" = public.my_company() and public.job_visible("jobId"));
create policy "photos_delete" on public.photos for delete to authenticated
  using ("companyId" = public.my_company() and (public.is_boss() or "createdBy" = auth.uid()));

-- ---------- Rechte ----------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
revoke all on all tables in schema public from anon;

-- ---------- Fotospeicher ----------
insert into storage.buckets ("id", "name", "public", "file_size_limit", "allowed_mime_types")
values ('photos', 'photos', false, 3145728, array['image/jpeg'])
on conflict ("id") do nothing;

create policy "photos_storage_select" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_company()::text);
create policy "photos_storage_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_company()::text);
create policy "photos_storage_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_company()::text
         and (public.is_boss() or owner_id = auth.uid()::text));

-- ---------- Live-Aktualisierung ----------
alter publication supabase_realtime add table
  public.companies, public.profiles, public.customers, public.buildings, public.jobs,
  public.appointments, public.time_entries, public.materials, public.photos;
