-- Neon PostgreSQL schema for iDRG Learning (compatible with Neon Auth + Neon Data API).
begin;

create schema if not exists idrg_private;
revoke all on schema idrg_private from public;

create table if not exists public.idrg_profiles (
  user_id uuid primary key,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  email text not null,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,30}$'),
  phone text not null check (phone ~ '^\+?[0-9 ()-]{8,25}$' and length(regexp_replace(phone,'[^0-9]','','g')) between 8 and 15),
  institution text not null check (length(trim(institution)) between 2 and 160),
  created_at timestamptz not null default now()
);

create table if not exists idrg_private.staff_roles (
  user_id uuid primary key,
  role text not null check (role = 'admin')
);

create table if not exists idrg_private.admin_allowlist (
  email text primary key check (email = lower(email))
);

create table if not exists idrg_private.bank_versions (
  revision text primary key,
  active boolean not null default false
);

create unique index if not exists one_active_idrg_bank
  on idrg_private.bank_versions (active) where active;

create table if not exists idrg_private.questions (
  revision text not null references idrg_private.bank_versions(revision),
  item_id text not null,
  case_id text not null,
  packet_id text not null check (packet_id in ('2-casemix','2-coding','4','6')),
  prompt text not null,
  options jsonb not null check (jsonb_array_length(options) = 5),
  correct smallint not null check (correct between 0 and 4),
  feedback text not null,
  primary key (revision, item_id)
);

create table if not exists public.idrg_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  packet_id text not null check (packet_id in ('2-casemix','2-coding','4','6')),
  revision text not null references idrg_private.bank_versions(revision),
  answers jsonb not null default '{}'::jsonb,
  case_index integer not null default 0,
  question_index integer not null default 0,
  version integer not null default 0,
  correct_count integer,
  total_count integer not null,
  submitted_at timestamptz,
  edit_count smallint not null default 0 check (edit_count between 0 and 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, packet_id, revision),
  check (case_index >= 0 and question_index between 0 and 3),
  check (correct_count is null or correct_count between 0 and total_count)
);

create table if not exists idrg_private.attempt_history (
  attempt_id uuid not null references public.idrg_attempts(id) on delete cascade,
  round smallint not null check (round between 0 and 1),
  answers jsonb not null,
  correct_count integer not null,
  total_count integer not null,
  submitted_at timestamptz not null,
  primary key (attempt_id, round)
);

create index if not exists idrg_attempts_owner on public.idrg_attempts(user_id);
create index if not exists idrg_attempts_revision on public.idrg_attempts(revision);
create index if not exists idrg_attempts_latest on public.idrg_attempts(user_id, packet_id, created_at desc);
create index if not exists idrg_attempts_latest_v2 on public.idrg_attempts(user_id, packet_id, created_at desc, id desc);
create index if not exists idrg_attempts_owner_created on public.idrg_attempts(user_id, created_at, id);
create index if not exists idrg_profiles_institution on public.idrg_profiles(institution);
create index if not exists idrg_profiles_created_user on public.idrg_profiles(created_at desc, user_id);
create index if not exists idrg_questions_revision_packet on idrg_private.questions(revision, packet_id, item_id) include (case_id);

create or replace function idrg_private.current_user_id() returns uuid
language sql stable set search_path = '' as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb ->> 'sub', '')
  )::uuid;
$$;

create or replace function idrg_private.current_user_email() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  addr text;
begin
  if uid is null then
    return null;
  end if;
  if to_regclass('neon_auth."user"') is not null then
    execute 'select email from neon_auth."user" where id::text = $1' into addr using uid::text;
  end if;
  if addr is null then
    addr := nullif(coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb ->> 'email', '');
  end if;
  return addr;
end;
$$;

create or replace function idrg_private.idrg_is_admin() returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  addr text;
begin
  if uid is null then
    return false;
  end if;
  if exists(select 1 from idrg_private.staff_roles r where r.user_id = uid and r.role = 'admin') then
    return true;
  end if;
  addr := idrg_private.current_user_email();
  return addr is not null and exists(select 1 from idrg_private.admin_allowlist a where a.email = lower(addr));
end;
$$;

create or replace function public.idrg_is_admin() returns boolean
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_is_admin();
$$;

alter table public.idrg_profiles enable row level security;
alter table public.idrg_attempts enable row level security;
alter table idrg_private.questions enable row level security;
alter table idrg_private.staff_roles enable row level security;
alter table idrg_private.admin_allowlist enable row level security;
alter table idrg_private.bank_versions enable row level security;
alter table idrg_private.attempt_history enable row level security;

revoke all on public.idrg_profiles, public.idrg_attempts from public, authenticated;
revoke all on idrg_private.questions, idrg_private.staff_roles, idrg_private.admin_allowlist, idrg_private.bank_versions, idrg_private.attempt_history from public, authenticated;
grant select on public.idrg_profiles, public.idrg_attempts to authenticated;
grant update(full_name, username, phone, institution) on public.idrg_profiles to authenticated;

drop policy if exists own_profile_read on public.idrg_profiles;
create policy own_profile_read on public.idrg_profiles for select to authenticated
  using (user_id = (select idrg_private.current_user_id()) or (select public.idrg_is_admin()));

drop policy if exists own_profile_update on public.idrg_profiles;
create policy own_profile_update on public.idrg_profiles for update to authenticated
  using (user_id = (select idrg_private.current_user_id()))
  with check (user_id = (select idrg_private.current_user_id()));

drop policy if exists own_attempt_read on public.idrg_attempts;
create policy own_attempt_read on public.idrg_attempts for select to authenticated
  using (user_id = (select idrg_private.current_user_id()) or (select public.idrg_is_admin()));

create or replace function idrg_private.idrg_load_account() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  owner_id uuid := idrg_private.current_user_id();
  result jsonb;
begin
  if owner_id is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'person', (select to_jsonb(p) from public.idrg_profiles p where p.user_id = owner_id),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.created_at, a.id)
      from public.idrg_attempts a
      where a.user_id = owner_id
    ), '[]'::jsonb),
    'admin', idrg_private.idrg_is_admin()
  ) into result;
  return result;
end;
$$;

create or replace function public.idrg_load_account() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_load_account();
$$;

create or replace function idrg_private.idrg_complete_profile(
  p_full_name text,
  p_username text,
  p_phone text,
  p_institution text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  person public.idrg_profiles;
  address text;
begin
  if uid is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode = '42501';
  end if;
  address := coalesce(idrg_private.current_user_email(), '');
  insert into public.idrg_profiles(user_id, email, full_name, username, phone, institution)
  values (uid, address, trim(p_full_name), lower(trim(p_username)), trim(p_phone), trim(p_institution))
  on conflict (user_id) do update set
    email = case when excluded.email <> '' then excluded.email else public.idrg_profiles.email end,
    full_name = excluded.full_name,
    username = excluded.username,
    phone = excluded.phone,
    institution = excluded.institution
  returning * into person;
  return to_jsonb(person);
end;
$$;

create or replace function public.idrg_complete_profile(
  p_full_name text,
  p_username text,
  p_phone text,
  p_institution text
) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_complete_profile(p_full_name, p_username, p_phone, p_institution);
$$;

create or replace function idrg_private.idrg_start_packet(p_packet_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  rev text;
  total integer;
  attempt public.idrg_attempts;
begin
  if uid is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode = '42501';
  end if;
  select revision into rev from idrg_private.bank_versions where active;
  select count(*) into total from idrg_private.questions where revision = rev and packet_id = p_packet_id;
  if total = 0 then
    raise exception 'Paket latihan belum tersedia.';
  end if;
  insert into public.idrg_attempts(user_id, packet_id, revision, total_count)
    values (uid, p_packet_id, rev, total)
    on conflict (user_id, packet_id, revision) do nothing;
  select * into attempt from public.idrg_attempts
    where user_id = uid and packet_id = p_packet_id and revision = rev;
  return to_jsonb(attempt);
end;
$$;

create or replace function public.idrg_start_packet(p_packet_id text) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_start_packet(p_packet_id);
$$;

create or replace function idrg_private.idrg_start_packet_versioned(p_packet_id text, p_revision text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  total integer;
  attempt public.idrg_attempts;
begin
  if uid is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode = '42501';
  end if;
  if p_revision is null or not exists(select 1 from idrg_private.bank_versions where revision = p_revision) then
    raise exception 'Versi soal belum tersedia. Muat ulang aplikasi.';
  end if;
  select count(*) into total from idrg_private.questions where revision = p_revision and packet_id = p_packet_id;
  if total = 0 then
    raise exception 'Paket latihan belum tersedia.';
  end if;
  insert into public.idrg_attempts(user_id, packet_id, revision, total_count)
    values (uid, p_packet_id, p_revision, total)
    on conflict (user_id, packet_id, revision) do nothing;
  select * into attempt from public.idrg_attempts
    where user_id = uid and packet_id = p_packet_id and revision = p_revision;
  return to_jsonb(attempt);
end;
$$;

create or replace function public.idrg_start_packet_versioned(p_packet_id text, p_revision text)
returns jsonb language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_start_packet_versioned(p_packet_id, p_revision);
$$;

create or replace function idrg_private.idrg_save_attempt(
  p_id uuid,
  p_answers jsonb,
  p_case_index integer,
  p_question_index integer,
  p_version integer
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  attempt public.idrg_attempts;
  case_count integer;
begin
  select * into attempt from public.idrg_attempts where id = p_id and user_id = uid for update;
  if not found then
    raise exception 'Latihan tidak ditemukan.' using errcode = '42501';
  end if;
  if attempt.submitted_at is not null then
    raise exception 'Paket sudah dikirim. Jawaban tidak dapat diubah.';
  end if;
  if p_version is null or attempt.version <> p_version then
    raise exception 'Data berubah pada perangkat lain. Muat ulang sebelum melanjutkan.' using errcode = '40001';
  end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' or octet_length(p_answers::text) > 20000 then
    raise exception 'Format jawaban tidak valid.';
  end if;
  if exists(
    select 1 from jsonb_each(p_answers) a
    left join idrg_private.questions q
      on q.item_id = a.key and q.packet_id = attempt.packet_id and q.revision = attempt.revision
    where q.item_id is null or jsonb_typeof(a.value) <> 'string'
      or a.value::text not in ('"0"','"1"','"2"','"3"','"4"')
  ) then
    raise exception 'Jawaban tidak sesuai dengan paket latihan.';
  end if;
  select count(distinct case_id) into case_count
    from idrg_private.questions
    where packet_id = attempt.packet_id and revision = attempt.revision;
  if p_case_index is null or p_case_index < 0 or p_case_index >= case_count
     or p_question_index is null or p_question_index not between 0 and 3 then
    raise exception 'Posisi soal tidak valid.';
  end if;
  update public.idrg_attempts
    set answers = p_answers,
        case_index = p_case_index,
        question_index = p_question_index,
        version = version + 1,
        updated_at = now()
    where id = p_id
    returning * into attempt;
  return to_jsonb(attempt);
end;
$$;

create or replace function public.idrg_save_attempt(
  p_id uuid,
  p_answers jsonb,
  p_case_index integer,
  p_question_index integer,
  p_version integer
) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_save_attempt(p_id, p_answers, p_case_index, p_question_index, p_version);
$$;

create or replace function idrg_private.idrg_submit_attempt(p_id uuid, p_answers jsonb, p_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  attempt public.idrg_attempts;
  saved jsonb;
  right_count integer;
begin
  select * into attempt from public.idrg_attempts where id = p_id and user_id = uid for update;
  if not found then
    raise exception 'Latihan tidak ditemukan.' using errcode = '42501';
  end if;
  if attempt.submitted_at is not null then
    return to_jsonb(attempt);
  end if;
  saved := public.idrg_save_attempt(p_id, p_answers, attempt.case_index, attempt.question_index, p_version);
  select count(*) into right_count
    from idrg_private.questions q
    where q.packet_id = attempt.packet_id
      and q.revision = attempt.revision
      and p_answers ->> q.item_id = q.correct::text;
  update public.idrg_attempts
    set correct_count = right_count,
        submitted_at = now(),
        updated_at = now(),
        version = version + 1
    where id = p_id
    returning * into attempt;
  insert into idrg_private.attempt_history(attempt_id, round, answers, correct_count, total_count, submitted_at)
    values (attempt.id, attempt.edit_count, attempt.answers, attempt.correct_count, attempt.total_count, attempt.submitted_at)
    on conflict (attempt_id, round) do nothing;
  return to_jsonb(attempt);
end;
$$;

create or replace function public.idrg_submit_attempt(p_id uuid, p_answers jsonb, p_version integer) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_submit_attempt(p_id, p_answers, p_version);
$$;

create or replace function idrg_private.idrg_reopen_attempt(p_id uuid, p_version integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  attempt public.idrg_attempts;
begin
  select * into attempt from public.idrg_attempts where id = p_id and user_id = uid for update;
  if not found then
    raise exception 'Latihan tidak ditemukan.' using errcode = '42501';
  end if;
  if attempt.edit_count = 1 and attempt.submitted_at is null then
    return to_jsonb(attempt);
  end if;
  if attempt.submitted_at is null then
    raise exception 'Paket belum dikirim.';
  end if;
  if attempt.edit_count >= 1 then
    raise exception 'Kesempatan revisi satu kali sudah digunakan.';
  end if;
  if p_version is null or p_version <> attempt.version then
    raise exception 'Data berubah pada perangkat lain. Muat ulang terlebih dahulu.' using errcode = '40001';
  end if;
  insert into idrg_private.attempt_history(attempt_id, round, answers, correct_count, total_count, submitted_at)
    values (attempt.id, 0, attempt.answers, attempt.correct_count, attempt.total_count, attempt.submitted_at)
    on conflict (attempt_id, round) do nothing;
  update public.idrg_attempts
    set edit_count = 1,
        correct_count = null,
        submitted_at = null,
        case_index = 0,
        question_index = 0,
        version = version + 1,
        updated_at = now()
    where id = p_id
    returning * into attempt;
  return to_jsonb(attempt);
end;
$$;

create or replace function public.idrg_reopen_attempt(p_id uuid, p_version integer) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_reopen_attempt(p_id, p_version);
$$;

create or replace function idrg_private.idrg_review(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  attempt public.idrg_attempts;
  result jsonb;
begin
  select * into attempt from public.idrg_attempts
    where id = p_id and (user_id = uid or public.idrg_is_admin()) and submitted_at is not null;
  if not found then
    raise exception 'Pembahasan tersedia setelah paket dikirim.' using errcode = '42501';
  end if;
  select jsonb_agg(jsonb_build_object(
    'item_id', q.item_id,
    'prompt', q.prompt,
    'options', q.options,
    'correct', q.correct,
    'feedback', q.feedback
  ) order by q.item_id) into result
  from idrg_private.questions q
  where q.packet_id = attempt.packet_id and q.revision = attempt.revision;
  return result;
end;
$$;

create or replace function public.idrg_review(p_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_review(p_id);
$$;

create or replace function idrg_private.idrg_attempt_history(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := idrg_private.current_user_id();
  result jsonb;
begin
  if not exists(
    select 1 from public.idrg_attempts a
    where a.id = p_id and (a.user_id = uid or public.idrg_is_admin())
  ) then
    raise exception 'Riwayat tidak dapat diakses.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.round), '[]'::jsonb) into result
  from idrg_private.attempt_history h
  where h.attempt_id = p_id;
  return result;
end;
$$;

create or replace function public.idrg_attempt_history(p_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_attempt_history(p_id);
$$;

create or replace function idrg_private.idrg_admin_dashboard(
  p_search text default '',
  p_institution text default '',
  p_page integer default 0,
  p_page_size integer default 25
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  result jsonb;
begin
  if not public.idrg_is_admin() then
    raise exception 'Akses pengelola diperlukan.' using errcode = '42501';
  end if;
  with filtered as materialized (
    select p.* from public.idrg_profiles p
    where (coalesce(p_institution, '') = '' or p.institution = p_institution)
      and (coalesce(p_search, '') = '' or position(lower(p_search) in lower(p.full_name || ' ' || p.email || ' ' || p.username)) > 0)
  ), latest_stats as materialized (
    select distinct on (a.user_id, a.packet_id)
      a.user_id, a.packet_id, a.correct_count, a.total_count, a.submitted_at
    from public.idrg_attempts a
    where a.user_id in (select user_id from filtered)
    order by a.user_id, a.packet_id, a.created_at desc, a.id desc
  ), overall as (
    select
      count(*) filter (where submitted_at is not null) as submitted,
      round(100.0 * sum(correct_count) filter (where submitted_at is not null)
        / nullif(sum(total_count) filter (where submitted_at is not null), 0), 1) as average
    from latest_stats
  ), page_base as (
    select f.* from filtered f
    order by f.created_at desc, f.user_id
    limit greatest(1, least(p_page_size, 100))
    offset greatest(0, p_page) * greatest(1, least(p_page_size, 100))
  ), page_rows as (
    select
      f.*,
      coalesce((
        select jsonb_agg(to_jsonb(a) order by a.packet_id)
        from (
          select distinct on (a.packet_id) a.*
          from public.idrg_attempts a
          where a.user_id = f.user_id
          order by a.packet_id, a.created_at desc, a.id desc
        ) a
      ), '[]'::jsonb) as attempts
    from page_base f
  ) select jsonb_build_object(
    'participants', (select count(*) from filtered),
    'submitted', (select submitted from overall),
    'average', (select average from overall),
    'materials', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.packet_id)
      from (
        select
          a.packet_id,
          count(*) as submitted,
          round(avg(100.0 * a.correct_count / nullif(a.total_count, 0)), 1) as average
        from latest_stats a
        where a.submitted_at is not null
        group by a.packet_id
      ) m
    ), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc, p.user_id) from page_rows p), '[]'::jsonb),
    'institutions', coalesce((
      select jsonb_agg(t.institution)
      from (select distinct institution from public.idrg_profiles order by institution) t
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.idrg_admin_dashboard(
  p_search text default '',
  p_institution text default '',
  p_page integer default 0,
  p_page_size integer default 25
) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_admin_dashboard(p_search, p_institution, p_page, p_page_size);
$$;

grant usage on schema idrg_private to authenticated;

revoke all on function
  idrg_private.current_user_id(),
  idrg_private.current_user_email(),
  idrg_private.idrg_is_admin(),
  public.idrg_is_admin(),
  idrg_private.idrg_load_account(),
  public.idrg_load_account(),
  idrg_private.idrg_complete_profile(text, text, text, text),
  public.idrg_complete_profile(text, text, text, text),
  idrg_private.idrg_start_packet(text),
  public.idrg_start_packet(text),
  idrg_private.idrg_start_packet_versioned(text, text),
  public.idrg_start_packet_versioned(text, text),
  idrg_private.idrg_save_attempt(uuid, jsonb, integer, integer, integer),
  public.idrg_save_attempt(uuid, jsonb, integer, integer, integer),
  idrg_private.idrg_submit_attempt(uuid, jsonb, integer),
  public.idrg_submit_attempt(uuid, jsonb, integer),
  idrg_private.idrg_reopen_attempt(uuid, integer),
  public.idrg_reopen_attempt(uuid, integer),
  idrg_private.idrg_review(uuid),
  public.idrg_review(uuid),
  idrg_private.idrg_attempt_history(uuid),
  public.idrg_attempt_history(uuid),
  idrg_private.idrg_admin_dashboard(text, text, integer, integer),
  public.idrg_admin_dashboard(text, text, integer, integer)
from public;

grant execute on function
  idrg_private.current_user_id(),
  idrg_private.idrg_is_admin(),
  public.idrg_is_admin(),
  idrg_private.idrg_load_account(),
  public.idrg_load_account(),
  idrg_private.idrg_complete_profile(text, text, text, text),
  public.idrg_complete_profile(text, text, text, text),
  idrg_private.idrg_start_packet(text),
  public.idrg_start_packet(text),
  idrg_private.idrg_start_packet_versioned(text, text),
  public.idrg_start_packet_versioned(text, text),
  idrg_private.idrg_save_attempt(uuid, jsonb, integer, integer, integer),
  public.idrg_save_attempt(uuid, jsonb, integer, integer, integer),
  idrg_private.idrg_submit_attempt(uuid, jsonb, integer),
  public.idrg_submit_attempt(uuid, jsonb, integer),
  idrg_private.idrg_reopen_attempt(uuid, integer),
  public.idrg_reopen_attempt(uuid, integer),
  idrg_private.idrg_review(uuid),
  public.idrg_review(uuid),
  idrg_private.idrg_attempt_history(uuid),
  public.idrg_attempt_history(uuid),
  idrg_private.idrg_admin_dashboard(text, text, integer, integer),
  public.idrg_admin_dashboard(text, text, integer, integer)
to authenticated;

do $$
declare
  r text;
begin
  foreach r in array array['anon', 'anonymous'] loop
    if exists(select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema idrg_private from %I', r);
      execute format('revoke all on all tables in schema public from %I', r);
      execute format('revoke all on all tables in schema idrg_private from %I', r);
      execute format('revoke all on all functions in schema public from %I', r);
      execute format('revoke all on all functions in schema idrg_private from %I', r);
    end if;
  end loop;
end $$;

commit;
