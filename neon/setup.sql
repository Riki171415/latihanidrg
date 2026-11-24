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
create index if not exists idrg_profiles_email_lower on public.idrg_profiles(lower(email));
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

create or replace function idrg_private.relink_migrated_user(p_owner_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  owner_email text;
  old_uid uuid;
begin
  if exists(select 1 from public.idrg_profiles where user_id = p_owner_id) then
    return;
  end if;
  owner_email := lower(nullif(trim(idrg_private.current_user_email()), ''));
  if owner_email is null then
    return;
  end if;
  select user_id into old_uid
  from public.idrg_profiles
  where lower(email) = owner_email and user_id <> p_owner_id
  order by created_at asc
  limit 1
  for update;
  if old_uid is not null then
    update public.idrg_profiles set user_id = p_owner_id where user_id = old_uid;
    update public.idrg_attempts set user_id = p_owner_id where user_id = old_uid;
    update idrg_private.staff_roles set user_id = p_owner_id where user_id = old_uid;
  end if;
end;
$$;

create or replace function idrg_private.idrg_load_account() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  owner_id uuid := idrg_private.current_user_id();
  result jsonb;
begin
  if owner_id is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode = '42501';
  end if;
  perform idrg_private.relink_migrated_user(owner_id);
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
language sql volatile security invoker set search_path = '' as $$
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
  perform idrg_private.relink_migrated_user(uid);
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
  idrg_private.relink_migrated_user(uuid),
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

begin;
update idrg_private.bank_versions set active=false where active and revision<>'2026-11-23.3';
insert into idrg_private.bank_versions(revision,active) values('2026-11-23.3',true) on conflict(revision) do update set active=true;
insert into idrg_private.questions(revision,item_id,case_id,packet_id,prompt,options,correct,feedback) values
('2026-11-23.3','M2-01-0','M2-01','2-casemix','Seorang petugas memasukkan kode ICD diagnosis dan tindakan, lalu menjalankan grouping dan memperoleh grup iDRG 2401210. Berapakah MDC dan Base DC dari grup tersebut?','["MDC 24 · Base DC 2410","MDC 24 · Base DC 24012","MDC 20 · Base DC 2001","MDC 21 · Base DC 2101","MDC 24 · Base DC 2401"]','4','MDC adalah dua digit pertama, yaitu 24. Base DC adalah empat digit pertama, yaitu 2401. Keduanya dibaca dari grup iDRG 2401210.'),
('2026-11-23.3','M2-01-1','M2-01','2-casemix','Dari grup iDRG 2401210, berapakah DC lengkap dan angka pembeda kelompok (split)-nya?','["DC 24012 · split 1","DC 24021 · split 1","DC 24012 · split 2","DC 2401210 · split 2","DC 24010 · split 0"]','2','DC lengkap adalah lima digit pertama, yaitu 24012. Angka kelima adalah 2; angka ini merupakan split atau pembeda kelompok pada kode tersebut.'),
('2026-11-23.3','M2-01-2','M2-01','2-casemix','Pada grup iDRG 2401210, digit keenam adalah 1 dan digit ketujuh adalah 0. Apa arti PTD 1 dan CL 0 tersebut?','["PTD 1 rawat jalan dan CL 0 Mild CC","PTD 1 rawat jalan dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Mild CC","PTD 1 rawat inap dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Severe CC"]','3','Pada grup ini, PTD 1 menunjukkan rawat inap. CL 0 menunjukkan No CC, yaitu tanpa komplikasi atau komorbiditas pada tingkat kelompok ini.'),
('2026-11-23.3','M2-01-3','M2-01','2-casemix','Petugas memasukkan kode ICD diagnosis dan tindakan sebelum menjalankan grouping. Dalam proses ini, kode yang dimasukkan petugas termasuk apa?','["Pesan kesalahan dari aplikasi.","Kode diagnosis utama yang dihasilkan aplikasi.","Kode tindakan yang dihasilkan aplikasi.","Hasil akhir pengelompokan iDRG.","Data masukan untuk pengelompokan iDRG."]','4','Kode ICD diagnosis dan tindakan adalah data masukan. Petugas memasukkan data tersebut lebih dahulu, kemudian aplikasi memprosesnya dan menghasilkan grup iDRG 2401210.'),
('2026-11-23.3','M2-02-0','M2-02','2-casemix','Berdasarkan resume persalinan, kode apa yang seharusnya menjadi diagnosis utama pada berkas ibu?','["Z37.0","O42.9","O80.0","O42.0","O42.1"]','3','Ketuban pecah dini menjadi alasan ibu datang dan dirawat. Karena persalinan dimulai dalam 24 jam, diagnosis utama pada contoh ini adalah O42.0.'),
('2026-11-23.3','M2-02-1','M2-02','2-casemix','Setelah diagnosis utama diperbaiki menjadi O42.0, pasangan kode apa yang dicatat sebagai diagnosis sekunder ibu?','["O80.0, Z38.0","O42.0, Z37.0","O80.0, Z37.0","O42.0, O80.0","O82.0, Z37.0"]','2','Gunakan O80.0 untuk cara persalinan spontan presentasi kepala dan Z37.0 untuk hasil kelahiran satu bayi hidup.'),
('2026-11-23.3','M2-02-2','M2-02','2-casemix','Kolom tindakan sudah berisi 73.59. Kode apa yang masih perlu ditambahkan untuk episiotomi?','["73.59","72.1","73.6","73.4","75.69"]','2','Tambahkan 73.6 karena catatan persalinan menyebut episiotomi sudah dilakukan.'),
('2026-11-23.3','M2-02-3','M2-02','2-casemix','Semua kode sudah diperbaiki. Apa langkah berikutnya agar petugas dapat mencatat hasil grouping yang benar?','["Jalankan grouper, salin hasilnya, lalu koreksi isian tanpa pengelompokan ulang.","Validasi isian, selesaikan ketidaksesuaian, jalankan grouper, lalu catat kode dan uraian dari hasil yang sama.","Koreksi diagnosis, lalu gunakan kode dan uraian hasil pengelompokan sebelumnya.","Validasi isian, lalu salin kode hasil baru dan uraian dari kasus lain dengan diagnosis serupa.","Catat kode serta uraian dari draf sebelum isian divalidasi."]','1','Periksa kembali isian yang sudah diperbaiki dan selesaikan pesan ketidaksesuaian. Jalankan grouping, lalu catat kode grup beserta uraiannya dari hasil yang sama.'),
('2026-11-23.3','M2-03-0','M2-03','2-coding','Sinusitis akut masih ditulis sebagai diagnosis utama. Setelah klarifikasi belum berhasil diperoleh, kode apa yang dipilih kembali sebagai diagnosis utama berdasarkan berkas perawatan ini?','["D06.0","C54.1","C53.0","C53.9","C53.1"]','2','Pilih C53.0 untuk karsinoma endoserviks. Pasien menjalani histerektomi total dan dirawat di layanan ginekologi. Pada contoh ini, setelah klarifikasi tidak berhasil, kedua catatan tersebut mendukung pemilihan kembali diagnosis utama dengan MB1.'),
('2026-11-23.3','M2-03-1','M2-03','2-coding','Penyakit yang menjadi fokus operasi justru ditulis sebagai diagnosis sekunder. Aturan MB manakah yang digunakan untuk memperbaiki pilihan diagnosis utama pada kasus ini?','["MB5","MB3","MB2","MB1","MB4"]','3','Gunakan MB1. Pada kasus ini, kondisi yang lebih berperan dalam perawatan ditulis sebagai diagnosis sekunder, sedangkan sinusitis akut ditulis sebagai diagnosis utama. Klarifikasi dokter sudah diupayakan tetapi belum berhasil.'),
('2026-11-23.3','M2-03-2','M2-03','2-coding','Catatan tindakan dan layanan apa yang mendukung pemilihan karsinoma endoserviks sebagai diagnosis utama?','["Hipertensi dan lama perawatan tiga minggu.","Sinusitis akut dan posisinya sebagai diagnosis utama pada draf.","Histerektomi total dan perawatan di layanan ginekologi.","Hipertensi dan urutan penulisannya pada resume.","Lama perawatan dan urutan diagnosis pada draf."]','2','Histerektomi total dan perawatan di layanan ginekologi mendukung bahwa perawatan berfokus pada kondisi ginekologi.'),
('2026-11-23.3','M2-03-3','M2-03','2-coding','Jika karsinoma endoserviks dipilih sebagai diagnosis utama, dua kondisi apa yang dicatat sebagai diagnosis sekunder pada kasus ini?','["Hipertensi saja","Karsinoma endoserviks dan hipertensi","Sinusitis akut dan karsinoma endoserviks","Sinusitis akut dan hipertensi","Sinusitis akut saja"]','3','Sinusitis akut dan hipertensi menempati diagnosis sekunder dalam contoh ini.'),
('2026-11-23.3','M2-04-0','M2-04','2-coding','Ketiga penyakit ditulis sebagai diagnosis utama. Klarifikasi belum berhasil diperoleh. Dengan mempertimbangkan layanan neurologi yang merawat pasien, kode apa yang dipilih sebagai diagnosis utama?','["G00.3","G00.1","G00.9","G00.2","G03.9"]','0','Pilih G00.3 untuk meningitis stafilokokus. Ketiga kondisi ditulis sebagai diagnosis utama, dan klarifikasi belum berhasil. Karena rincian penanganan belum membedakan fokus perawatan, layanan neurologi menjadi petunjuk pada contoh MB2 ini.'),
('2026-11-23.3','M2-04-1','M2-04','2-coding','Dokter menulis beberapa penyakit sekaligus sebagai diagnosis utama. Aturan MB manakah yang digunakan untuk memilih satu diagnosis utama?','["MB4","MB2","MB3","MB1","MB5"]','1','MB2 digunakan untuk memilih satu diagnosis utama ketika beberapa kondisi ditulis sebagai diagnosis utama.'),
('2026-11-23.3','M2-04-2','M2-04','2-coding','Rincian klinis belum menunjukkan penyakit mana yang paling banyak ditangani. Informasi apa dalam berkas yang membantu menentukan pilihan diagnosis utama pada contoh ini?','["Katarak ditulis paling awal pada kolom diagnosis utama.","Terdapat tiga entri pada kolom diagnosis utama.","Kolom diagnosis sekunder belum diisi.","Pasien dirawat selama lima minggu.","Pasien dirawat oleh layanan neurologi."]','4','Informasi yang digunakan pada contoh ini adalah layanan neurologi yang merawat pasien. Petunjuk tersebut dibaca setelah klarifikasi gagal dan rincian penanganan belum cukup membedakan kondisi utama.'),
('2026-11-23.3','M2-04-3','M2-04','2-coding','Jika meningitis stafilokokus dipilih sebagai diagnosis utama, dua kondisi apa yang dicatat sebagai diagnosis sekunder pada kasus ini?','["Meningitis stafilokokus dan penyakit jantung iskemik","Penyakit jantung iskemik saja","Katarak saja","Katarak dan penyakit jantung iskemik","Katarak dan meningitis stafilokokus"]','3','Katarak dan penyakit jantung iskemik menjadi diagnosis sekunder dalam contoh ini.'),
('2026-11-23.3','M2-05-0','M2-05','2-coding','Dokter menyatakan koma berkaitan dengan diabetes melitus dependen insulin. Kode apa yang mencakup diabetes beserta koma dan dipilih sebagai diagnosis utama?','["R40.2","E10.1","E10.0","E10.9","E11.0"]','2','E10.0 mencakup diabetes melitus dependen insulin dengan koma dalam satu kode. Dokter sudah mengaitkan koma dengan diabetes, dan diabetes mendapat penanganan selama perawatan.'),
('2026-11-23.3','M2-05-1','M2-05','2-coding','Koma ditulis sebagai diagnosis utama, padahal diabetes penyebabnya sudah diketahui dan ditangani. Aturan MB manakah yang digunakan untuk memperbaikinya?','["MB3","MB4","MB5","MB1","MB2"]','0','Gunakan MB3. Koma adalah gejala atau manifestasi dari diabetes yang sudah diketahui dan ditangani. Karena itu, penyakit penyebab dipilih kembali sebagai diagnosis utama pada contoh ini.'),
('2026-11-23.3','M2-05-2','M2-05','2-coding','Dua keterangan apa yang menunjukkan hubungan koma dengan diabetes dan bahwa diabetes ditangani selama perawatan?','["Dokter mencatat penyakit jantung iskemik, dan pasien dirawat oleh layanan endokrinologi.","Koma ditulis paling awal, dan diabetes ditulis pada kolom diagnosis sekunder.","Diabetes dicatat pada resume, tetapi hubungan dengan koma belum dijelaskan.","Pasien menerima insulin, tetapi penyebab koma tidak disebutkan.","Dokter mengaitkan koma dengan diabetes, dan dosis insulin disesuaikan selama perawatan."]','4','Catatan mengaitkan koma dengan diabetes dan mencatat penentuan dosis insulin selama rawat.'),
('2026-11-23.3','M2-05-3','M2-05','2-coding','Kode E10.0 sudah digunakan untuk diabetes dengan koma. Apakah kode gejala koma masih perlu ditambahkan?','["Tidak. Koma sudah tercakup dalam E10.0.","Ya. R40.2 ditambahkan untuk setiap koma meskipun sudah tercakup dalam kode kombinasi.","Ya. E10.0 hanya menunjukkan jenis diabetes tanpa komplikasinya.","Ya. Koma tetap menjadi diagnosis utama dan E10.0 menjadi diagnosis sekunder.","Tidak. E10.0 diganti dengan R40.2 agar hanya satu kode digunakan."]','0','Koma sudah tercakup dalam E10.0, sehingga tidak perlu diberi kode gejala terpisah.'),
('2026-11-23.3','M2-06-0','M2-06','2-coding','Dokter menulis penyakit jantung kongenital dan defek septum ventrikel untuk kelainan yang sama. Kode apa yang paling spesifik sebagai diagnosis utama?','["Q21.0","Q21.9","Q21.2","Q21.1","Q24.9"]','0','Q21.0 untuk defek septum ventrikel.'),
('2026-11-23.3','M2-06-1','M2-06','2-coding','Diagnosis sekunder menyebut kelainan yang lebih spesifik daripada diagnosis utama, tetapi keduanya merujuk pada kondisi yang sama. Aturan MB manakah yang digunakan?','["MB2","MB3","MB5","MB1","MB4"]','4','Gunakan MB4. Istilah defek septum ventrikel menjelaskan kelainan yang sama secara lebih spesifik daripada istilah umum penyakit jantung kongenital.'),
('2026-11-23.3','M2-06-2','M2-06','2-coding','Dari istilah pada resume, mana yang secara jelas menyebut jenis kelainan pada sekat jantung?','["Penyakit jantung kongenital tanpa rincian.","Diagnosis sekunder pada resume.","Defek septum ventrikel.","Kelainan jantung bawaan tanpa rincian.","Diagnosis utama pada resume."]','2','“Defek septum ventrikel” menyebut lokasi defek secara spesifik.'),
('2026-11-23.3','M2-06-3','M2-06','2-coding','Defek septum ventrikel sudah diberi kode. Apakah istilah umum “penyakit jantung kongenital” untuk kelainan yang sama masih perlu diberi kode terpisah?','["Kedua istilah diberi kode sebagai dua kelainan yang berbeda.","Istilah umum tetap menjadi diagnosis utama; diagnosis spesifik menjadi diagnosis sekunder.","Tidak diberi kode terpisah karena kedua istilah merujuk pada kondisi yang sama.","Istilah umum ditambahkan sebagai diagnosis sekunder untuk kondisi yang sama.","Seluruh pengodean ditunda meskipun diagnosis spesifik sudah tersedia."]','2','Tidak ada kode tambahan untuk sebutan umum karena kedua istilah merujuk pada kondisi yang sama.'),
('2026-11-23.3','M2-07-0','M2-07','2-coding','Dokter menulis “kolesistitis akut atau pankreatitis akut” dan klarifikasi belum berhasil diperoleh. Berdasarkan aturan MB5, kode apa yang dipilih sebagai diagnosis utama?','["K80.0","K81.1","K81.0","K81.9","K85.9"]','2','Pilih K81.0 untuk kolesistitis akut. Pada contoh MB5 ini, kedua penyakit ditulis sebagai alternatif dan klarifikasi belum berhasil; diagnosis yang ditulis pertama dipilih sebagai diagnosis utama.'),
('2026-11-23.3','M2-07-1','M2-07','2-coding','Diagnosis utama ditulis sebagai dua pilihan yang dihubungkan kata “atau”. Aturan MB manakah yang digunakan?','["MB5","MB3","MB2","MB4","MB1"]','0','MB5 mengatur pemilihan diagnosis utama saat dokter menuliskan diagnosis alternatif.'),
('2026-11-23.3','M2-07-2','M2-07','2-coding','Pada catatan “kolesistitis akut atau pankreatitis akut”, bagaimana diagnosis utama dipilih menurut aturan MB5 untuk kasus ini?','["Kata “atau” menandai alternatif; diagnosis yang ditulis pertama dipilih pada contoh ini.","Kata “atau” menandai alternatif; diagnosis yang ditulis terakhir dipilih.","Kedua alternatif dicatat sebagai dua diagnosis utama.","Kedua alternatif diperlakukan sebagai dua kondisi yang pasti ada.","Diagnosis yang namanya lebih umum dipilih tanpa mempertimbangkan urutannya."]','0','Kata “atau” menunjukkan dua pilihan diagnosis, bukan dua penyakit yang dipastikan terjadi bersama. Sesuai aturan MB5 pada contoh ini, pilih diagnosis yang ditulis pertama, yaitu kolesistitis akut.'),
('2026-11-23.3','M2-07-3','M2-07','2-coding','Pankreatitis akut hanya disebut sebagai pilihan setelah kata “atau”. Apakah kondisi itu boleh langsung dicatat sebagai diagnosis sekunder?','["Ya. Setiap diagnosis yang ditulis setelah kata “atau” menjadi diagnosis sekunder.","Ya. Kedua alternatif selalu dianggap sebagai dua penyakit yang terjadi bersamaan.","Tidak. Pankreatitis akut hanya ditulis sebagai alternatif, bukan kondisi sekunder yang dipastikan ada.","Ya. Semua istilah pada kolom diagnosis utama harus diberi kode terpisah.","Ya. Pankreatitis dipilih sebagai diagnosis sekunder karena ditulis terakhir."]','2','Tidak. Dalam pernyataan dokter, pankreatitis akut merupakan alternatif, sehingga belum ditetapkan sebagai diagnosis sekunder.'),
('2026-11-23.3','M2-08-0','M2-08','2-coding','Pada perikarditis tuberkulosa, kode apa yang menunjukkan tuberkulosis sebagai penyakit penyebab?','["A18.0","A18.3","A19.9","I32.0","A18.8"]','4','A18.8 mewakili tuberkulosis sebagai penyakit penyebab dalam pasangan ini.'),
('2026-11-23.3','M2-08-1','M2-08','2-coding','Kode apa yang menunjukkan perikarditis sebagai manifestasi tuberkulosis pada kasus ini?','["A18.8","I32.0","I31.0","I32.1","I30.9"]','1','I32.0 mewakili perikarditis sebagai manifestasi penyakit penyebab.'),
('2026-11-23.3','M2-08-2','M2-08','2-coding','Untuk perikarditis tuberkulosa, pasangan kode dan penempatan diagnosis utama serta sekundernya manakah yang benar?','["Diagnosis utama A18.8 · diagnosis sekunder I32.0","Diagnosis utama I32.0 · diagnosis sekunder A18.8","Diagnosis utama A18.3 · diagnosis sekunder I32.0","Diagnosis utama A18.8 · diagnosis sekunder I32.1","Diagnosis utama A18.8 · diagnosis sekunder I30.9"]','0','A18.8 ditempatkan sebagai diagnosis utama dan I32.0 sebagai diagnosis sekunder.'),
('2026-11-23.3','M2-08-3','M2-08','2-coding','Dokter hanya menulis “perikarditis tuberkulosa”. Mengapa pengodean diagnosis ini tetap membutuhkan dua kode?','["Setiap penyakit infeksi selalu harus menggunakan dua kode.","Satu diagnosis klinis tersebut harus diwakili oleh pasangan kode penyebab dan manifestasi sesuai klasifikasi.","Kolom diagnosis sekunder yang kosong harus diisi dengan satu kode tambahan.","Kode manifestasi menggantikan kode penyebab bila dokter hanya menulis satu diagnosis.","Kode penyebab hanya digunakan jika ada diagnosis tuberkulosis lain."]','1','Perikarditis tuberkulosa diwakili oleh dua kode sesuai klasifikasi: A18.8 untuk penyakit penyebab dan I32.0 untuk manifestasinya pada perikardium. Dua kode ini berasal dari satu diagnosis dokter, bukan dari dua penyakit baru yang ditambahkan koder.'),
('2026-11-23.3','M2-09-0','M2-09','2-coding','Pada laporan A, kraniotomi dilakukan untuk mencapai tumor. Tindakan mana yang kemudian dilakukan untuk menangani tumornya?','["Pembukaan tengkorak saja.","Biopsi tumor saja.","Pencitraan tumor.","Penutupan akses operasi.","Reseksi tumor."]','4','Tindakan untuk menangani tumor pada laporan A adalah reseksi tumor. Kraniotomi dilakukan lebih dahulu untuk mencapai lokasi tumor.'),
('2026-11-23.3','M2-09-1','M2-09','2-coding','Pada laporan A, kraniotomi hanya menjadi jalan masuk untuk reseksi tumor. Apakah kraniotomi perlu diberi kode tersendiri?','["Kraniotomi diberi kode terpisah karena dilakukan lebih dahulu daripada reseksi.","Kraniotomi diberi kode, sedangkan reseksi tumor tidak diberi kode.","Kraniotomi dan reseksi tumor sama-sama tidak diberi kode.","Kraniotomi dicatat sebagai diagnosis sekunder.","Kraniotomi tidak diberi kode terpisah karena merupakan akses menuju reseksi tumor."]','4','Kraniotomi pada laporan A hanya menjadi jalan masuk untuk reseksi tumor. Sesuai petunjuk omit code pada contoh ini, kraniotomi tersebut tidak diberi kode terpisah.'),
('2026-11-23.3','M2-09-2','M2-09','2-coding','Pada laporan B, operasi berhenti setelah kraniotomi tanpa reseksi tumor. Kode apa yang digunakan untuk kraniotomi tersebut?','["02.02","01.23","01.31","01.24","01.51"]','3','Gunakan 01.24. Pada laporan B, tindakan berhenti pada kraniotomi; tidak ada reseksi tumor atau tindakan lanjutan lain.'),
('2026-11-23.3','M2-09-3','M2-09','2-coding','Sebelum memilih kode reseksi tumor pada laporan A, rincian apa yang perlu diperiksa pada laporan operasi lengkap?','["Lama rawat dan kelas perawatan.","Lokasi anatomi tumor dan teknik reseksi pada laporan operasi lengkap.","Nama operator dan nomor kamar operasi.","Waktu mulai anestesi dan lama rawat.","Letak insisi kulit saja."]','1','Telusuri lokasi anatomi tumor dan bagaimana reseksi dilakukan pada laporan operasi yang lengkap.'),
('2026-11-23.3','M4-01-0','M4-01','4','Pasien sudah terintubasi sebelum tiba. Kapan durasi penggunaan ventilator mulai dihitung untuk perawatan di rumah sakit penerima?','["Sejak intubasi pertama di rumah sakit pengirim.","Sejak surat rujukan dibuat.","Sejak masuk rumah sakit penerima, dengan bukti penggunaan ventilator pada episode tersebut.","Sejak pasien meninggalkan rumah sakit pengirim.","Sejak pengajuan administrasi rujukan disetujui."]','2','Durasi untuk rumah sakit penerima dimulai sejak pasien masuk dengan bukti penggunaan ventilator pada perawatan tersebut. Waktu intubasi di rumah sakit pengirim tidak dipakai sebagai awal durasi rumah sakit penerima.'),
('2026-11-23.3','M4-01-1','M4-01','4','Catatan waktu apa yang harus dicocokkan untuk menentukan awal penggunaan ventilator di rumah sakit penerima?','["Waktu intubasi di pengirim dan surat rujukan saja.","Tanggal masuk tanpa jam dan resume pulang saja.","Waktu ekstubasi dan daftar diagnosis saja.","Waktu masuk dan catatan penggunaan ventilator di rumah sakit penerima.","Lama rawat keseluruhan dan jadwal kunjungan dokter."]','3','Cocokkan waktu masuk pasien dengan catatan pemasangan atau penggunaan ventilator di rumah sakit penerima. Kedua catatan diperlukan untuk menentukan awal durasi yang sesuai.'),
('2026-11-23.3','M4-01-2','M4-01','4','Jika rumah sakit penerima kemudian merujuk pasien ke rumah sakit berikutnya, kapan penghitungan durasi ventilasi di rumah sakit penerima dihentikan?','["Saat pasien dipasang ventilator di rumah sakit berikutnya.","Saat pasien terdaftar di rumah sakit berikutnya.","Saat pasien diekstubasi di rumah sakit berikutnya.","Saat ventilator dilepas di rumah sakit penerima sebelum pasien dirujuk lagi.","Saat surat rujukan ke rumah sakit berikutnya diterbitkan."]','3','Jika rumah sakit penerima merujuk pasien lagi, penghitungan untuk rumah sakit penerima berakhir saat ventilator dilepas di rumah sakit tersebut. Jangan meneruskan durasinya sampai penggunaan alat di rumah sakit berikutnya.'),
('2026-11-23.3','M4-01-3','M4-01','4','Waktu masuk serta waktu awal dan akhir penggunaan ventilator belum tercantum. Apakah total jam ventilasi di rumah sakit penerima sudah dapat dihitung?','["Sudah. Gunakan lama rawat keseluruhan sebagai durasi ventilasi.","Sudah. Gunakan waktu intubasi di rumah sakit pengirim sebagai awal hitungan.","Belum. Waktu awal dan akhir penggunaan ventilator di rumah sakit penerima belum tersedia.","Sudah. Hitung sejak surat rujukan dibuat sampai pasien pulang.","Tidak dapat dihitung pada semua pasien rujukan, meskipun catatan waktunya lengkap."]','2','Belum. Jam awal dan akhir penggunaan ventilator yang relevan belum tersedia.'),
('2026-11-23.3','M4-02-0','M4-02','4','Agen trombolitik sudah diberikan melalui injeksi atau infus. Kode tindakan apa yang sesuai?','["99.20","99.29","99.19","99.10","99.21"]','3','99.10 untuk injeksi atau infus agen trombolitik.'),
('2026-11-23.3','M4-02-1','M4-02','4','Dokumen apa yang menjadi bukti bahwa agen trombolitik sudah diberikan pada perawatan ini?','["Instruksi awal dokter tanpa catatan pelaksanaan.","Resep obat tanpa konfirmasi pemberian.","Catatan pemberian obat pada episode perawatan sebelumnya.","Daftar obat yang tersedia di farmasi.","Lembar pemberian obat atau catatan pelaksanaan yang membuktikan pemberian pada episode ini."]','4','Gunakan catatan pelaksanaan atau lembar pemberian obat yang menunjukkan tindakan sudah dikerjakan.'),
('2026-11-23.3','M4-02-2','M4-02','4','Pada berkas lain, hanya ada instruksi pemberian trombolitik tanpa catatan bahwa obat sudah diberikan. Apa yang seharusnya dilakukan koder?','["Jangan tetapkan sebagai tindakan terlaksana sebelum ada bukti pemberian.","Tetapkan kode segera berdasarkan instruksi dokter.","Tetapkan kode jika obat sudah dipesan dari farmasi.","Tetapkan kode berdasarkan jadwal pemberian yang direncanakan.","Tetapkan kode jika nama obat muncul pada daftar resep."]','0','Tunda pengodean sampai tersedia bukti bahwa pemberian telah dilakukan.'),
('2026-11-23.3','M4-02-3','M4-02','4','Jika hanya ada catatan pemberian trombolitik tanpa diagnosis akhir dokter, apakah koder boleh menyimpulkan sendiri penyakit pasien?','["Tidak. Diagnosis perlu didasarkan pada penetapan dokter, bukan disimpulkan dari tindakan saja.","Ya. Pemberian trombolitik cukup untuk menetapkan diagnosis stroke tertentu.","Ya. Rute infus menentukan diagnosis penyakitnya.","Ya. Dosis trombolitik dapat digunakan menggantikan diagnosis akhir dokter.","Ya. Nama kelompok obat sudah cukup untuk menetapkan kode diagnosis spesifik."]','0','Tidak. Diagnosis spesifik mengikuti diagnosis yang ditetapkan dokter, sementara catatan pemberian mendukung kode tindakan.'),
('2026-11-23.3','M4-03-0','M4-03','4','Pasien datang untuk kontrol setelah vitrektomi dan tidak menjalani perawatan luka. Kode diagnosis utama apa yang digunakan sesuai kasus pada ICS?','["Z48.8","Z01.0","Z09.0","Z48.0","Z09.9"]','0','Z48.8 digunakan untuk kontrol pascaoperasi mata pada contoh ini.'),
('2026-11-23.3','M4-03-1','M4-03','4','Hipertensi esensial ditulis sebagai diagnosis sekunder. Kode apa yang sesuai?','["I95.9","I15.9","R03.0","I11.9","I10"]','4','I10 untuk hipertensi esensial.'),
('2026-11-23.3','M4-03-2','M4-03','4','Dokter hanya menulis “funduskopi”. Pertanyaan mana yang meminta penjelasan teknik pemeriksaan tanpa menyarankan jawaban tertentu?','["Mohon tuliskan bahwa pemeriksaan dilakukan dengan kamera fundus.","Mohon tuliskan bahwa pemeriksaan dilakukan dengan oftalmoskop.","Mohon gunakan kode foto fundus tanpa menambahkan rincian pemeriksaan.","Mohon jelaskan alat dan teknik pemeriksaan fundus yang digunakan pada kunjungan ini.","Mohon tentukan teknik pemeriksaan dari riwayat vitrektomi saja."]','3','Minta dokter menjelaskan alat dan teknik yang digunakan. Jangan langsung meminta dokter menyebut kamera fundus atau oftalmoskop, karena tekniknya belum diketahui dari catatan.'),
('2026-11-23.3','M4-03-3','M4-03','4','Untuk membedakan teknik pemeriksaan, pasangan kode manakah yang benar untuk foto fundus dan oftalmoskopi?','["Foto fundus 95.12 · oftalmoskopi 16.21","Foto fundus 95.11 · oftalmoskopi 95.12","Foto fundus 95.11 · oftalmoskopi 16.21","Foto fundus 16.21 · oftalmoskopi 95.11","Foto fundus 95.12 · oftalmoskopi 95.11"]','2','Foto fundus dikode 95.11. Oftalmoskopi dikode 16.21.'),
('2026-11-23.3','M4-04-0','M4-04','4','Pada laporan A, lesi telinga luar diangkat untuk terapi. Kode tindakan apa yang sesuai?','["18.31","18.21","18.39","18.12","18.29"]','4','18.29 untuk eksisi lesi telinga luar pada laporan A.'),
('2026-11-23.3','M4-04-1','M4-04','4','Pada laporan B, dokter mengambil sampel jaringan telinga luar untuk biopsi. Kode tindakan apa yang sesuai?','["18.29","18.31","19.0","18.12","18.21"]','3','18.12 untuk biopsi telinga luar pada laporan B.'),
('2026-11-23.3','M4-04-2','M4-04','4','Sampel pada laporan B sudah diperiksa dengan patologi anatomi. Kelompok kode manakah yang perlu diperiksa untuk memilih kode pemeriksaan tersebut?','["91.81","90.89","91.86-","91.85","91.82"]','2','Periksa kelompok 91.86- untuk pemeriksaan patologi anatomi sesuai petunjuk ICS. Tanda hubung berarti kode perlu dilengkapi sesuai rincian pemeriksaan; 91.86- bukan kode akhir untuk langsung dimasukkan.'),
('2026-11-23.3','M4-04-3','M4-04','4','Apa perbedaan tujuan pengambilan jaringan pada laporan A dan laporan B?','["Laporan A: biopsi; laporan B: pengangkatan untuk terapi.","Keduanya biopsi karena lokasi tindakannya sama.","Laporan A: pengangkatan untuk terapi; laporan B: pengambilan sampel untuk biopsi.","Keduanya pengangkatan terapeutik karena sama-sama mengambil jaringan.","Laporan A: pemeriksaan tanpa pengambilan jaringan; laporan B: pengangkatan seluruh lesi."]','2','Pada laporan A, lesi diangkat untuk terapi. Pada laporan B, jaringan diambil untuk diperiksa sebagai biopsi.'),
('2026-11-23.3','M4-05-0','M4-05','4','Untuk TB resistan obat, informasi tambahan apa yang perlu dikodekan selain kode dasar TB sesuai petunjuk ICS?','["Gejala pernapasan dan riwayat penyakit.","Pemeriksaan mikrobiologi dan tindakan radiologi.","Kategori resistansi TB (TB Episode of Care) dan jenis obat terkait resistansi (Drug Types).","Penyebab luar dan cedera.","Pemeriksaan radiologi dan administrasi kunjungan."]','2','ICS meminta penelusuran dua kelompok tambahan: TB Episode of Care untuk kategori resistansi TB, dan Drug Types untuk jenis obat terkait resistansi. Kategori resistansi dan obat yang terlibat harus diperjelas sebelum kode spesifik dipilih.'),
('2026-11-23.3','M4-05-1','M4-05','4','Resume hanya menulis “TB RO”. Dua informasi apa yang masih dibutuhkan untuk memilih kode dasar TB?','["Lokasi TB dan dasar konfirmasi diagnosis.","Kelas rawat dan lama pengobatan.","Usia pasien dan jadwal kontrol.","Rute pemberian obat dan tanggal pulang.","Jumlah obat dan jenis kepesertaan."]','0','Lokasi TB dan dasar konfirmasi diagnosis masih perlu diketahui untuk memilih kode dasar yang sesuai. Istilah “TB RO” saja belum menjelaskan kedua informasi tersebut.'),
('2026-11-23.3','M4-05-2','M4-05','4','Dokumen apa yang perlu diperiksa untuk mengetahui kategori resistansi dan obat yang terbukti resistan?','["Daftar stok obat antituberkulosis.","Tagihan obat tanpa hasil uji atau penilaian dokter.","Resume yang hanya menulis “TB RO” tanpa rincian.","Hasil uji kepekaan atau resistansi beserta penilaian klinis dokter yang terkait.","Riwayat terapi tanpa pemeriksaan resistansi atau keterangan dokter."]','3','Gunakan hasil uji kepekaan atau resistansi, bersama catatan klinis yang mengaitkan hasil tersebut dengan obat yang disebut.'),
('2026-11-23.3','M4-05-3','M4-05','4','Kategori resistansi dan obat yang resistan belum tertulis. Pertanyaan mana yang tepat untuk meminta penjelasan dokter?','["Mohon tetapkan TB MDR agar pengodean dapat diselesaikan.","Mohon pilih kategori resistansi paling berat.","Mohon nyatakan resistansi rifampisin meskipun hasil uji belum tersedia.","Mohon pilih MDR atau XDR tanpa perlu menjelaskan obat yang resistan.","Mohon jelaskan kategori resistansi dan obat yang terbukti resistan, bila dapat ditentukan."]','4','Tanyakan kategori resistansi dan obat yang terbukti resistan bila dapat ditentukan. Jangan mengarahkan DPJP ke kategori atau obat tertentu.'),
('2026-11-23.3','M4-06-0','M4-06','4','Dokter sudah melakukan PTCA. Kode tindakan apa yang digunakan?','["36.06","00.63","36.07","00.61","00.66"]','4','00.66 untuk tindakan PTCA.'),
('2026-11-23.3','M4-06-1','M4-06','4','PTCA dilakukan pada satu pembuluh koroner. Kode tambahan apa yang menunjukkan jumlah pembuluh tersebut?','["00.42","00.41","00.40","00.43","00.45"]','2','00.40 menunjukkan tindakan pada satu pembuluh.'),
('2026-11-23.3','M4-06-2','M4-06','4','Dokter memasang satu stent. Kode tambahan apa yang menunjukkan jumlah stent tersebut?','["00.47","00.45","00.48","00.46","00.40"]','1','00.45 menunjukkan jumlah stent yang dipasang, yaitu satu.'),
('2026-11-23.3','M4-06-3','M4-06','4','Jenis stent belum tercantum dalam laporan. Apa yang harus diperiksa atau ditanyakan sebelum memilih kode jenis stent?','["Pilih drug-eluting stent karena hanya satu stent yang dipasang.","Pilih non-drug-eluting stent jika jenisnya belum tertulis.","Tentukan jenis stent dari jumlah pembuluh yang ditangani.","Salin jenis stent dari laporan tindakan pasien lain.","Periksa catatan implan atau minta operator menjelaskan jenis stent yang dipasang."]','4','Periksa kartu atau catatan implan, atau minta operator menjelaskan jenis stent yang dipasang pada episode ini.'),
('2026-11-23.3','M4-07-0','M4-07','4','Pada resume A, dokter menulis apendisitis akut dengan perforasi dan peritonitis umum. Kode diagnosis apa yang sesuai?','["K35.3","K35.8","K36","K37","K35.2"]','4','K35.2 untuk apendisitis akut dengan peritonitis umum.'),
('2026-11-23.3','M4-07-1','M4-07','4','Pada resume B, dokter menulis apendisitis akut dengan peritonitis lokal. Kode diagnosis apa yang sesuai?','["K35.3","K35.8","K37","K36","K35.2"]','0','K35.3 untuk apendisitis akut dengan peritonitis lokal.'),
('2026-11-23.3','M4-07-2','M4-07','4','Istilah apa pada resume A yang menunjukkan bahwa peritonitisnya lebih luas daripada pada resume B?','["Apendisitis akut.","Perforasi tanpa keterangan luas peritonitis.","Peritonitis umum.","Tindakan operasi.","Lokasi apendiks."]','2','Frasa “peritonitis umum” menunjukkan luas peritonitis pada episode A.'),
('2026-11-23.3','M4-07-3','M4-07','4','Kode apendisitis dengan peritonitis umum sudah digunakan pada resume A. Apakah peritonitis masih perlu diberi kode terpisah?','["Ya. Semua peritonitis selalu memerlukan kode terpisah.","Ya. Kode apendisitis hanya menunjukkan lokasi organ.","Ya. Perforasi selalu mengharuskan satu kode peritonitis tambahan.","Tidak. Peritonitis sudah tercakup dalam kode kombinasi yang dipilih.","Tidak. Peritonitis tidak disebut dalam resume A."]','3','Peritonitis umum sudah tercakup dalam kode kombinasi apendisitis akut pada episode A.'),
('2026-11-23.3','M4-08-0','M4-08','4','Dokter berhasil mengeluarkan batu saluran empedu melalui ERCP. Kode tindakan apa yang sesuai?','["51.88","51.87","51.10","51.11","51.85"]','0','51.88 untuk pengangkatan batu dari saluran empedu secara endoskopik pada contoh ini.'),
('2026-11-23.3','M4-08-1','M4-08','4','Pengambilan batu melalui ERCP sudah diberi kode. Apakah 51.10 untuk ERCP diagnostik perlu ditambahkan pada tindakan yang sama?','["Ya. Setiap ERCP terapeutik selalu memerlukan kode ERCP diagnostik tambahan.","Tidak. Pada kasus ini, kode pengambilan batu sudah mencakup pelaksanaan melalui ERCP.","Ya. Judul “ERCP” harus diberi kode terpisah dari uraian tindakan pada sesi yang sama.","Ya. Pengambilan batu dan ERCP pada laporan ini dianggap sebagai dua sesi berbeda.","Tidak. ERCP hanya direncanakan dan belum dilakukan."]','1','Untuk contoh ini, gunakan kode tindakan yang spesifik. Kode ERCP diagnostik 51.10 tidak ditambahkan pada sesi yang sama.'),
('2026-11-23.3','M4-08-2','M4-08','4','Bagian laporan mana yang membuktikan batu sudah dikeluarkan, bukan baru direncanakan untuk dikeluarkan?','["Judul laporan menyebut ERCP.","Diagnosis mencantumkan batu saluran empedu.","Instruksi mencantumkan rencana pengambilan batu.","Jadwal tindakan mencantumkan nama operator.","Uraian operator menyatakan batu berhasil dikeluarkan dari saluran empedu secara endoskopik."]','4','Uraian operator menyatakan bahwa batu telah dikeluarkan dari saluran empedu melalui endoskop.'),
('2026-11-23.3','M4-08-3','M4-08','4','Jika laporan hanya menulis “ERCP”, informasi apa yang masih perlu diperiksa sebelum memberi kode pengambilan batu?','["Lama rawat dan kelas perawatan.","Riwayat pengambilan batu pada episode sebelumnya.","Identitas operator dan nomor ruangan saja.","Biaya tindakan dan jadwal pemeriksaan.","Uraian tindakan yang terlaksana, termasuk lokasi batu dan bukti bahwa batu dikeluarkan."]','4','Periksa uraian prosedur untuk memastikan bahwa pengambilan batu terlaksana dan bahwa batunya berasal dari saluran empedu.'),
('2026-11-23.3','M4-09-0','M4-09','4','Kode tindakan apa yang digunakan untuk artroskopi lutut?','["80.27","80.25","80.26","80.21","81.45"]','2','80.26 untuk artroskopi lutut.'),
('2026-11-23.3','M4-09-1','M4-09','4','Selain artroskopi, dokter melakukan reparasi ligamen krusiat kategori other repair. Kode apa yang sesuai untuk reparasi tersebut?','["80.26","81.47","81.46","81.45","81.44"]','3','Gunakan 81.45 untuk other repair of the cruciate ligaments, yaitu kategori reparasi lain ligamen krusiat sebagaimana dicatat pada laporan.'),
('2026-11-23.3','M4-09-2','M4-09','4','Menurut daftar pada ICS, apakah reparasi ligamen krusiat yang dilakukan bersama artroskopi ini termasuk prosedur kompleks?','["Tidak. Artroskopi dengan reparasi ligamen tetap selalu termasuk prosedur diagnostik.","Tidak. Tindakan pada sendi yang sama tidak boleh dinilai sebagai prosedur kompleks.","Ya. Reparasi tersebut termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.","Ya. Semua artroskopi termasuk kompleks, tanpa melihat tindakan tambahannya.","Tidak. Reparasi hanya dianggap kompleks jika dilakukan pada hari yang berbeda."]','2','Ya. Reparasi yang didokumentasikan termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.'),
('2026-11-23.3','M4-09-3','M4-09','4','Dokumen mana yang membuktikan reparasi ligamen krusiat sudah dilakukan, meskipun judul lembar tindakan hanya menyebut artroskopi?','["Judul laporan yang hanya menulis artroskopi lutut.","Diagnosis yang menyebut keluhan lutut.","Jadwal operasi tanpa catatan pelaksanaan.","Uraian operasi yang menyebut ligamen krusiat dan reparasi yang telah dilakukan.","Formulir persetujuan tindakan tanpa laporan operasi."]','3','Uraian operasi menyebut ligamen yang ditangani dan menyatakan bahwa reparasi dilakukan.'),
('2026-11-23.3','M4-10-0','M4-10','4','Pada laporan A, dokter mengeksisi jaringan luka saat debridemen. Kode tindakan apa yang sesuai?','["86.59","86.22","86.28","86.04","86.09"]','1','86.22 untuk debridemen eksisional pada contoh ini.'),
('2026-11-23.3','M4-10-1','M4-10','4','Pada laporan B, dokter menulis debridemen noneksisional. Kode tindakan apa yang sesuai?','["86.28","86.59","86.09","86.22","86.04"]','0','86.28 untuk debridemen noneksisional.'),
('2026-11-23.3','M4-10-2','M4-10','4','Keterangan mana dalam laporan A yang menunjukkan debridemen dilakukan dengan teknik eksisional?','["Operator mencatat eksisi jaringan luka.","Dokter hanya mencatat lokasi luka.","Jadwal menyebut rencana perawatan luka.","Catatan menyebut pembersihan tanpa eksisi.","Kolom prosedur hanya menulis debridemen tanpa teknik."]','0','Frasa “mengeksisi jaringan luka” menunjukkan teknik eksisional.'),
('2026-11-23.3','M4-10-3','M4-10','4','Pada laporan C, dokter hanya menulis “debridemen”. Apa pertanyaan yang tepat untuk memperjelas tindakan sebelum kode dipilih?','["Mohon nyatakan debridemen eksisional agar kode dapat dipilih.","Mohon nyatakan kedalaman tertentu tanpa memeriksa laporan operasi.","Mohon ganti judul tindakan menjadi debridemen eksisional.","Mohon tentukan kode dari judul tindakan tanpa rincian teknik.","Mohon jelaskan teknik debridemen dan jaringan yang ditangani pada tindakan ini."]','4','Tanyakan teknik debridemen serta jaringan yang ditangani tanpa menyarankan teknik tertentu.'),
('2026-11-23.3','M4-11-0','M4-11','4','Dokter menulis “diabetes melitus tipe 2 dengan ulkus diabetik” pada resume utama. Kode apa yang mencakup diagnosis tersebut sesuai contoh ICS?','["E10.5","E11.9","E11.6","E11.4","E11.5"]','4','E11.5 adalah kode kombinasi yang digunakan untuk diagnosis pada contoh ICS ini.'),
('2026-11-23.3','M4-11-1','M4-11','4','Kata mana pada resume utama yang menunjukkan dokter mengaitkan ulkus dengan diabetes?','["“Diabetes melitus tipe 2” tanpa keterangan komplikasi.","“Ulkus” tanpa keterangan hubungan dengan diabetes.","“Ulkus diabetik”.","Dua diagnosis yang dicatat pada baris terpisah tanpa penjelasan.","Riwayat diabetes saja."]','2','“Ulkus diabetik” menyatakan bahwa dokter mengaitkan ulkus dengan diabetes.'),
('2026-11-23.3','M4-11-2','M4-11','4','Kode untuk diabetes dengan ulkus sudah digunakan. Sesuai contoh ICS ini, apakah ulkus masih perlu diberi kode terpisah?','["Ya. Semua ulkus harus selalu diberi kode terpisah.","Ya. Diabetes harus dikode tanpa komplikasi lalu ditambah kode ulkus.","Tidak. Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi.","Ya. Hubungan diabetes dan ulkus belum dinyatakan pada resume utama.","Tidak. Ulkus hanya merupakan rencana diagnosis."]','2','Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi sehingga tidak dicatat lagi sebagai diagnosis sekunder.'),
('2026-11-23.3','M4-11-3','M4-11','4','Pada resume pembanding, dokter menulis diabetes dan ulkus tanpa menjelaskan kaitannya. Pertanyaan apa yang tepat untuk memperjelas hubungan kedua kondisi?','["Mohon pastikan bahwa ulkus merupakan komplikasi diabetes.","Mohon jelaskan hubungan klinis antara diabetes dan ulkus, bila ada.","Mohon ganti diagnosis ulkus menjadi ulkus diabetik.","Mohon nyatakan bahwa ulkus tidak berkaitan dengan diabetes.","Mohon pilih kode kombinasi tanpa menjelaskan hubungan klinis."]','1','Tanyakan apakah ulkus memiliki hubungan klinis dengan diabetes. Pertanyaan ini meminta penjelasan, tanpa mengarahkan dokter untuk menyatakan bahwa ulkus pasti merupakan komplikasi diabetes.'),
('2026-11-23.3','M6-01-0','M6-01','6','Pada berkas A, dokter belum menulis stadium AKI. Apa pertanyaan yang tepat untuk meminta penjelasan dokter?','["Mohon tetapkan stadium 3 karena ada pemasangan kateter pada berkas lain.","Mohon jelaskan stadium AKI pada episode ini, bila dapat ditentukan secara klinis.","Mohon tetapkan stadium tertinggi untuk mengantisipasi perburukan.","Mohon tetapkan stadium 1 karena belum ada rincian pemeriksaan.","Mohon tentukan stadium hanya dari nama tindakan pada berkas lain."]','1','Minta DPJP menjelaskan stadium AKI bila dapat ditentukan, tanpa mengusulkan salah satu stadium.'),
('2026-11-23.3','M6-01-1','M6-01','6','Apakah koder sudah dapat memilih kode AKI untuk stadium tertentu dari informasi dalam berkas A?','["Sudah. Istilah AKI saja sudah menentukan stadiumnya.","Sudah. AKI tanpa keterangan selalu dianggap stadium 1.","Belum. Stadium perlu didokumentasikan atau dikonfirmasi oleh dokter.","Sudah. Semua AKI tanpa stadium dikode sebagai stadium 2.","Sudah. Jenis kateter pada berkas B menentukan stadium pasien pada berkas A."]','2','Belum. Stadium perlu didokumentasikan atau dikonfirmasi oleh dokter.'),
('2026-11-23.3','M6-01-2','M6-01','6','Pada berkas B, kateter dialisis bertunnel sudah dipasang. Kode tindakan spesifik apa yang digunakan sesuai ICS?','["38.950","39.27","39.95","38.95","54.932"]','0','38.950 sesuai untuk pemasangan tunneled dialysis catheter pada contoh ICS ini.'),
('2026-11-23.3','M6-01-3','M6-01','6','Pada berkas B, kateter dialisis sudah dipasang tetapi tidak ada catatan sesi dialisis. Apakah kode pelaksanaan dialisis boleh langsung ditambahkan?','["Tidak. Pelaksanaan dialisis memerlukan bukti tersendiri, terpisah dari pemasangan akses.","Ya. Pemasangan kateter selalu berarti sesi dialisis sudah selesai.","Ya. Nama kateter yang mengandung kata dialisis sudah cukup sebagai bukti.","Ya. Laporan pemasangan akses menggantikan catatan sesi dialisis.","Ya. Kode pemasangan akses dan kode pelaksanaan dialisis mempunyai arti yang sama."]','0','Pemasangan kateter menyediakan akses dialisis. Hal itu belum membuktikan sesi dialisis sudah dilakukan. Kode pelaksanaan dialisis memerlukan catatan pelaksanaan tersendiri.'),
('2026-11-23.3','M6-02-0','M6-02','6','Ibu mengalami ketuban pecah dini dan mulai bersalin dalam 24 jam. Kode apa yang menjadi diagnosis utama pada berkas ibu?','["O42.0","Z37.0","O80.0","O42.9","O42.1"]','0','O42.0 untuk ketuban pecah dini dengan awal persalinan dalam 24 jam.'),
('2026-11-23.3','M6-02-1','M6-02','6','Untuk persalinan spontan presentasi kepala, kode dan penempatan diagnosis manakah yang benar pada berkas ibu?','["O81.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis utama","O42.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis sekunder","O82.0 sebagai diagnosis sekunder"]','3','O80.0 dicatat sebagai diagnosis sekunder untuk cara persalinan spontan presentasi kepala.'),
('2026-11-23.3','M6-02-2','M6-02','6','Untuk hasil satu bayi lahir hidup, kode dan penempatan diagnosis manakah yang benar pada berkas ibu?','["Z38.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder","Z37.1 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis utama"]','3','Z37.0 dicatat sebagai diagnosis sekunder untuk hasil satu bayi lahir hidup.'),
('2026-11-23.3','M6-02-3','M6-02','6','Persalinan spontan dan episiotomi sudah dilakukan. Pasangan kode tindakan manakah yang sesuai contoh ICS?','["72.1, 73.6","73.59, 72.1","73.59, 73.6","73.4, 73.6","73.59, 75.69"]','2','Gunakan 73.59 dan 73.6. Kode 73.6 adalah kode episiotomi.'),
('2026-11-23.3','M6-03-0','M6-03','6','Dokter menetapkan hipoglikemia neonatal. Kode diagnosis utama apa yang digunakan pada berkas bayi?','["P70.0","P70.4","P70.1","P70.8","P70.9"]','1','P70.4 untuk hipoglikemia neonatal pada contoh ini.'),
('2026-11-23.3','M6-03-1','M6-03','6','Bayi lahir tunggal di rumah sakit. Kode dan penempatan diagnosis manakah yang benar untuk mencatat status kelahirannya?','["Z37.0 sebagai diagnosis sekunder","Z38.1 sebagai diagnosis sekunder","Z38.0 sebagai diagnosis utama","Z37.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder"]','4','Z38.0 dicatat sebagai diagnosis sekunder untuk bayi tunggal yang lahir di rumah sakit.'),
('2026-11-23.3','M6-03-2','M6-03','6','Dua keterangan pada catatan kelahiran mana yang mendasari pemilihan Z38.0?','["Bayi tunggal dan berat lahir 3.000 gram.","Bayi cukup bulan dan berat lahir 3.000 gram.","Hipoglikemia dan hasil pemeriksaan penunjang.","Bayi tunggal dan lahir di rumah sakit.","Bayi cukup bulan dan diagnosis hipoglikemia."]','3','Bayi lahir tunggal dan tempat lahirnya di rumah sakit.'),
('2026-11-23.3','M6-03-3','M6-03','6','Apakah Z37.0 merupakan kode untuk mencatat status kelahiran pada berkas bayi ini?','["Ya. Z37.0 digunakan untuk semua bayi yang lahir di rumah sakit.","Ya. Z37.0 menjadi diagnosis utama untuk hipoglikemia neonatal.","Tidak. Z37.0 digunakan untuk hasil persalinan pada berkas ibu; status kelahiran bayi memakai kategori Z38.","Ya. Z37.0 menggantikan kode status kelahiran bayi.","Tidak. Status kelahiran bayi tidak perlu dicatat meskipun tersedia pada sumber."]','2','Z37.0 mencatat hasil persalinan pada episode ibu. Pada episode bayi, status kelahiran dicatat dengan kode yang sesuai dari kategori Z38.'),
('2026-11-23.3','M6-04-0','M6-04','6','Pasien masuk karena pielonefritis akut, lalu mengalami sepsis selama dirawat. Sesuai urutan kejadian pada contoh ICS ini, kode apa yang menjadi diagnosis utama?','["N39.0","A41.5","N11.9","N10","N12"]','3','N10 untuk pielonefritis akut sebagai diagnosis utama pada episode ini.'),
('2026-11-23.3','M6-04-1','M6-04','6','Kode diagnosis sekunder apa yang digunakan untuk sepsis akibat E. coli sesuai contoh ICS ini?','["A41.0","A41.8","A40.9","A41.5","A41.9"]','3','A41.5 untuk sepsis akibat organisme Gram-negatif lain, sebagaimana digunakan pada contoh ICS ini.'),
('2026-11-23.3','M6-04-2','M6-04','6','Kode tambahan apa yang menunjukkan E. coli sebagai penyebab pielonefritis?','["B96.8","B96.5","B96.2","B96.1","B95.6"]','2','B96.2 mencatat E. coli sebagai organisme penyebab.'),
('2026-11-23.3','M6-04-3','M6-04','6','Catatan mana yang menunjukkan bahwa dokter sudah menetapkan diagnosis sepsis, bukan hanya menemukan kultur positif?','["Kultur darah positif tanpa diagnosis sepsis dari dokter.","Demam dan menggigil saja.","DPJP secara jelas menuliskan diagnosis “sepsis akibat E. coli”.","Tekanan darah 120/70 mmHg saja.","Kultur urin positif tanpa penetapan diagnosis sepsis."]','2','DPJP secara eksplisit menetapkan “sepsis akibat E. coli”. Kultur positif membantu mengidentifikasi organisme dan harus dibaca bersama diagnosis dokter.'),
('2026-11-23.3','M6-05-0','M6-05','6','Dokter menetapkan cedera organ dalam dada sebagai kondisi utama dan fraktur terbuka humerus sebagai kondisi lain. Pasangan kode diagnosis utama dan sekunder manakah yang sesuai?','["Diagnosis utama S42.21 · diagnosis sekunder S27.7","Diagnosis utama S27.7 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.31","Diagnosis utama S27.9 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.20"]','1','S27.7 menjadi diagnosis utama untuk cedera multipel organ intratorakal. S42.21 menjadi diagnosis sekunder untuk fraktur terbuka humerus proksimal dalam contoh ini.'),
('2026-11-23.3','M6-05-1','M6-05','6','Pasien mengemudikan mobil yang menabrak pohon. Kode penyebab luar apa yang digunakan sesuai contoh ICS?','["V49.9","V47.59","V89.2","V47.69","V47.09"]','1','V47.59 adalah kode penyebab luar yang digunakan pada contoh ICS ini.'),
('2026-11-23.3','M6-05-2','M6-05','6','WSD pada dada dan ORIF pada humerus sudah dilakukan. Pasangan kode tindakan manakah yang sesuai contoh ICS?','["WSD 34.04 · ORIF 79.31","WSD 34.04 · ORIF 79.19","WSD 79.39 · ORIF 34.04","WSD 34.04 · ORIF 79.39","WSD 34.91 · ORIF 79.39"]','3','WSD dikode 34.04 dan ORIF humerus dikode 79.39.'),
('2026-11-23.3','M6-05-3','M6-05','6','Cedera pada dada dan humerus termasuk dalam dua kelompok lokasi tubuh yang mana saat menelaah kriteria MDC 31?','["Dada dan ekstremitas atas","Abdomen dan ekstremitas atas","Pelvis dan ekstremitas atas","Kepala dan dada","Dada dan ekstremitas bawah"]','0','Lokasi cedera adalah dada dan ekstremitas atas atau anggota gerak atas. Humerus termasuk ekstremitas atas. Informasi lokasi ini digunakan untuk menelaah kriteria trauma; penetapan MDC tetap mengikuti kriteria grouper.'),
('2026-11-23.3','M6-06-0','M6-06','6','Pasien datang khusus untuk menjalani terapi rehabilitasi. Kode diagnosis utama apa yang sesuai untuk kunjungan ini?','["Z50.8","Z50.0","Z50.1","Z51.8","M54.5"]','2','Z50.1 untuk kunjungan terapi fisik pada contoh ini.'),
('2026-11-23.3','M6-06-1','M6-06','6','Rehabilitasi diberikan karena nyeri punggung bawah. Kode diagnosis sekunder apa yang digunakan sesuai contoh ICS?','["Z50.1","M54.5","M54.4","M54.6","M54.9"]','1','M54.5 adalah kode nyeri punggung bawah yang digunakan pada contoh ini.'),
('2026-11-23.3','M6-06-2','M6-06','6','Peregangan sudah dilakukan. Kode tindakan apa yang sesuai?','["93.27","93.11","93.28","93.35","93.12"]','0','93.27 untuk peregangan pada contoh ini.'),
('2026-11-23.3','M6-06-3','M6-06','6','Terapi inframerah sudah dilakukan. Kode tindakan apa yang sesuai?','["93.32","93.27","93.35","93.34","93.39"]','2','93.35 untuk terapi inframerah pada contoh ini.'),
('2026-11-23.3','M6-07-0','M6-07','6','Terapi whirlpool sudah diberikan, tetapi aplikasi menampilkan “rehabilitasi tanpa prosedur”. Apa kesalahan pada isian aplikasi?','["Kode prosedur whirlpool belum diisi meskipun terapi sudah dilaksanakan.","Kode diagnosis utama belum diisi.","Kode diagnosis sekunder belum diisi.","Terapi whirlpool belum dilaksanakan karena hasil grouper menyebut tanpa prosedur.","Kode hasil grouper sudah menjadi pengganti kode prosedur whirlpool."]','0','Catatan terapi menyatakan whirlpool sudah diberikan, tetapi kolom tindakan belum diisi. Petugas perlu memasukkan kode tindakan yang sesuai, bukan menganggap terapi tidak dilakukan hanya karena uraian hasil grouping.'),
('2026-11-23.3','M6-07-1','M6-07','6','Kode tindakan apa yang harus dimasukkan untuk terapi whirlpool yang sudah diberikan?','["93.35","93.31","93.33","93.39","93.32"]','4','93.32 untuk terapi whirlpool.'),
('2026-11-23.3','M6-07-2','M6-07','6','Kode whirlpool sudah ditambahkan. Apa langkah berikutnya pada aplikasi grouper?','["Gunakan hasil lama dan cukup ubah uraiannya.","Validasi kembali isian yang diperbarui, lalu jalankan pengelompokan ulang.","Catat kode prosedur tanpa menjalankan pengelompokan ulang.","Jalankan pengelompokan ulang sebelum memasukkan kode prosedur.","Ubah diagnosis utama tanpa memeriksa catatan terapi."]','1','Periksa dan validasi kembali isian yang sudah ditambahkan, lalu jalankan grouping ulang. Hasil sebelum perbaikan tidak digunakan sebagai hasil akhir setelah isian berubah.'),
('2026-11-23.3','M6-07-3','M6-07','6','Setelah grouping dijalankan ulang, hasil apa yang harus diperiksa dan dicatat petugas?','["Pertahankan kode dan uraian hasil lama tanpa memeriksa hasil baru.","Periksa apakah keluaran lama sudah berubah, lalu catat kode dan uraian yang benar-benar muncul setelah pengelompokan ulang.","Catat kode hasil yang diperkirakan muncul meskipun aplikasi belum dijalankan ulang.","Catat kode prosedur saja tanpa meninjau hasil pengelompokan.","Nyatakan koreksi berhasil hanya karena kolom prosedur sudah terisi."]','1','Baca hasil grouping yang baru, periksa apakah masalah “rehabilitasi tanpa prosedur” sudah teratasi, lalu catat kode dan uraian yang benar-benar tampil. Jangan menebak kode hasil setelah perbaikan.'),
('2026-11-23.3','M6-08-0','M6-08','6','Pada laporan A, pasien sudah menjalani CT kepala. Kode pemeriksaan apa yang sesuai?','["87.04","88.38","87.02","87.03","88.91"]','3','87.03 untuk CT kepala.'),
('2026-11-23.3','M6-08-1','M6-08','6','Pada laporan B, pasien sudah menjalani MRI kepala. Kode pemeriksaan apa yang sesuai?','["88.97","87.03","88.91","88.93","88.92"]','2','88.91 untuk MRI otak dan batang otak pada contoh ICS ini.'),
('2026-11-23.3','M6-08-2','M6-08','6','Bahan kontras sudah diberikan pada CT kepala dalam laporan A. Kode tambahan apa yang digunakan sesuai ICS?','["99.10","99.290","99.21","99.20","99.250"]','1','99.290 menunjukkan pemberian bahan kontras pada pemeriksaan CT yang tercatat.'),
('2026-11-23.3','M6-08-3','M6-08','6','Bahan kontras sudah diberikan pada MRI kepala dalam laporan B. Kode tambahan apa yang digunakan sesuai ICS?','["99.290","99.10","99.21","99.250","99.20"]','0','99.290 juga digunakan untuk pemberian bahan kontras pada pemeriksaan MRI yang tercatat.')
on conflict(revision,item_id) do nothing;
commit;

begin;
insert into idrg_private.bank_versions(revision,active) values('2026-11-23.4',false) on conflict(revision) do nothing;
insert into idrg_private.questions(revision,item_id,case_id,packet_id,prompt,options,correct,feedback) values
('2026-11-23.4','M2-01-0','M2-01','2-casemix','Seorang petugas memasukkan kode ICD diagnosis dan tindakan, lalu menjalankan grouping dan memperoleh grup iDRG 2401210. Berapakah MDC dan Base DC dari grup tersebut?','["MDC 24 · Base DC 2410","MDC 24 · Base DC 24012","MDC 20 · Base DC 2001","MDC 21 · Base DC 2101","MDC 24 · Base DC 2401"]','4','MDC adalah dua digit pertama, yaitu 24. Base DC adalah empat digit pertama, yaitu 2401. Keduanya dibaca dari grup iDRG 2401210.'),
('2026-11-23.4','M2-01-1','M2-01','2-casemix','Dari grup iDRG 2401210, berapakah DC lengkap dan angka pembeda kelompok (split)-nya?','["DC 24012 · split 1","DC 24021 · split 1","DC 24012 · split 2","DC 2401210 · split 2","DC 24010 · split 0"]','2','DC lengkap adalah lima digit pertama, yaitu 24012. Angka kelima adalah 2; angka ini merupakan split atau pembeda kelompok pada kode tersebut.'),
('2026-11-23.4','M2-01-2','M2-01','2-casemix','Pada grup iDRG 2401210, digit keenam adalah 1 dan digit ketujuh adalah 0. Apa arti PTD 1 dan CL 0 tersebut?','["PTD 1 rawat jalan dan CL 0 Mild CC","PTD 1 rawat jalan dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Mild CC","PTD 1 rawat inap dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Severe CC"]','3','Pada grup ini, PTD 1 menunjukkan rawat inap. CL 0 menunjukkan No CC, yaitu tanpa komplikasi atau komorbiditas pada tingkat kelompok ini.'),
('2026-11-23.4','M2-01-3','M2-01','2-casemix','Petugas memasukkan kode ICD diagnosis dan tindakan sebelum menjalankan grouping. Dalam proses ini, kode yang dimasukkan petugas termasuk apa?','["Pesan kesalahan dari aplikasi.","Kode diagnosis utama yang dihasilkan aplikasi.","Kode tindakan yang dihasilkan aplikasi.","Hasil akhir pengelompokan iDRG.","Data masukan untuk pengelompokan iDRG."]','4','Kode ICD diagnosis dan tindakan adalah data masukan. Petugas memasukkan data tersebut lebih dahulu, kemudian aplikasi memprosesnya dan menghasilkan grup iDRG 2401210.'),
('2026-11-23.4','M2-02-0','M2-02','2-casemix','Berdasarkan resume persalinan, kode apa yang seharusnya menjadi diagnosis utama pada berkas ibu?','["Z37.0","O42.9","O80.0","O42.0","O42.1"]','3','Ketuban pecah dini menjadi alasan ibu datang dan dirawat. Karena persalinan dimulai dalam 24 jam, diagnosis utama pada contoh ini adalah O42.0.'),
('2026-11-23.4','M2-02-1','M2-02','2-casemix','Setelah diagnosis utama diperbaiki menjadi O42.0, pasangan kode apa yang dicatat sebagai diagnosis sekunder ibu?','["O80.0, Z38.0","O42.0, Z37.0","O80.0, Z37.0","O42.0, O80.0","O82.0, Z37.0"]','2','Gunakan O80.0 untuk cara persalinan spontan presentasi kepala dan Z37.0 untuk hasil kelahiran satu bayi hidup.'),
('2026-11-23.4','M2-02-2','M2-02','2-casemix','Kolom tindakan sudah berisi 73.59. Kode apa yang masih perlu ditambahkan untuk episiotomi?','["73.59","72.1","73.6","73.4","75.69"]','2','Tambahkan 73.6 karena catatan persalinan menyebut episiotomi sudah dilakukan.'),
('2026-11-23.4','M2-02-3','M2-02','2-casemix','Semua kode sudah diperbaiki. Apa langkah berikutnya agar petugas dapat mencatat hasil grouping yang benar?','["Jalankan grouper, salin hasilnya, lalu koreksi isian tanpa pengelompokan ulang.","Validasi isian, selesaikan ketidaksesuaian, jalankan grouper, lalu catat kode dan uraian dari hasil yang sama.","Koreksi diagnosis, lalu gunakan kode dan uraian hasil pengelompokan sebelumnya.","Validasi isian, lalu salin kode hasil baru dan uraian dari kasus lain dengan diagnosis serupa.","Catat kode serta uraian dari draf sebelum isian divalidasi."]','1','Periksa kembali isian yang sudah diperbaiki dan selesaikan pesan ketidaksesuaian. Jalankan grouping, lalu catat kode grup beserta uraiannya dari hasil yang sama.'),
('2026-11-23.4','M2-03-0','M2-03','2-coding','Sinusitis akut masih ditulis sebagai diagnosis utama. Setelah klarifikasi belum berhasil diperoleh, kode apa yang dipilih kembali sebagai diagnosis utama berdasarkan berkas perawatan ini?','["D06.0","C54.1","C53.0","C53.9","C53.1"]','2','Pilih C53.0 untuk karsinoma endoserviks. Pasien menjalani histerektomi total dan dirawat di layanan ginekologi. Pada contoh ini, setelah klarifikasi tidak berhasil, kedua catatan tersebut mendukung pemilihan kembali diagnosis utama dengan MB1.'),
('2026-11-23.4','M2-03-1','M2-03','2-coding','Penyakit yang menjadi fokus operasi justru ditulis sebagai diagnosis sekunder. Aturan MB manakah yang digunakan untuk memperbaiki pilihan diagnosis utama pada kasus ini?','["MB5","MB3","MB2","MB1","MB4"]','3','Gunakan MB1. Pada kasus ini, kondisi yang lebih berperan dalam perawatan ditulis sebagai diagnosis sekunder, sedangkan sinusitis akut ditulis sebagai diagnosis utama. Klarifikasi dokter sudah diupayakan tetapi belum berhasil.'),
('2026-11-23.4','M2-03-2','M2-03','2-coding','Catatan tindakan dan layanan apa yang mendukung pemilihan karsinoma endoserviks sebagai diagnosis utama?','["Hipertensi dan lama perawatan tiga minggu.","Sinusitis akut dan posisinya sebagai diagnosis utama pada draf.","Histerektomi total dan perawatan di layanan ginekologi.","Hipertensi dan urutan penulisannya pada resume.","Lama perawatan dan urutan diagnosis pada draf."]','2','Histerektomi total dan perawatan di layanan ginekologi mendukung bahwa perawatan berfokus pada kondisi ginekologi.'),
('2026-11-23.4','M2-03-3','M2-03','2-coding','Jika karsinoma endoserviks dipilih sebagai diagnosis utama, dua kondisi apa yang dicatat sebagai diagnosis sekunder pada kasus ini?','["Hipertensi saja","Karsinoma endoserviks dan hipertensi","Sinusitis akut dan karsinoma endoserviks","Sinusitis akut dan hipertensi","Sinusitis akut saja"]','3','Sinusitis akut dan hipertensi menempati diagnosis sekunder dalam contoh ini.'),
('2026-11-23.4','M2-04-0','M2-04','2-coding','Tiga penyakit ditulis sebagai diagnosis utama dan klarifikasi belum dijawab. Berdasarkan fokus pemeriksaan serta pengobatan pada episode neurologi ini, kode mana yang dipilih sebagai diagnosis utama?','["G00.3","G00.1","G00.9","G00.2","G03.9"]','0','G00.3 mewakili meningitis stafilokokus. Resume menulis beberapa diagnosis sebagai utama; pada MB2, fokus pemeriksaan dan pengobatan membantu memilih satu kondisi. Meningitis mendapat evaluasi cairan serebrospinal, kultur, antibiotik, dan pemantauan neurologis. Spesialisasi layanan saja bukan satu-satunya dasar.'),
('2026-11-23.4','M2-04-1','M2-04','2-coding','Dokter menulis beberapa penyakit sekaligus sebagai diagnosis utama. Aturan MB manakah yang digunakan untuk memilih satu diagnosis utama?','["MB4","MB2","MB3","MB1","MB5"]','1','MB2 digunakan untuk memilih satu diagnosis utama ketika beberapa kondisi ditulis sebagai diagnosis utama.'),
('2026-11-23.4','M2-04-2','M2-04','2-coding','Bukti mana yang paling kuat menunjukkan fokus perawatan untuk memilih satu diagnosis utama dari beberapa diagnosis yang tertulis?','["Katarak ditulis paling awal.","Kolom diagnosis sekunder kosong.","Jumlah diagnosis pada resume ada tiga.","Lama rawat lima minggu saja.","Pemeriksaan cairan serebrospinal, kultur, dan terapi infeksi sistem saraf."]','4','Pada MB2, penentuan didasarkan pada kondisi yang terutama diperiksa atau diobati. Dokumentasi pemeriksaan dan terapi meningitis lebih kuat daripada urutan tulisan, lama rawat, atau nama layanan semata.'),
('2026-11-23.4','M2-04-3','M2-04','2-coding','Jika meningitis stafilokokus dipilih sebagai diagnosis utama, dua kondisi apa yang dicatat sebagai diagnosis sekunder pada kasus ini?','["Meningitis stafilokokus dan penyakit jantung iskemik","Penyakit jantung iskemik saja","Katarak saja","Katarak dan penyakit jantung iskemik","Katarak dan meningitis stafilokokus"]','3','Katarak dan penyakit jantung iskemik menjadi diagnosis sekunder dalam contoh ini.'),
('2026-11-23.4','M2-05-0','M2-05','2-coding','Dokter menyatakan koma berkaitan dengan diabetes melitus dependen insulin. Kode apa yang mencakup diabetes beserta koma dan dipilih sebagai diagnosis utama?','["R40.2","E10.1","E10.0","E10.9","E11.0"]','2','E10.0 mencakup diabetes melitus dependen insulin dengan koma dalam satu kode. Dokter sudah mengaitkan koma dengan diabetes, dan diabetes mendapat penanganan selama perawatan.'),
('2026-11-23.4','M2-05-1','M2-05','2-coding','Koma ditulis sebagai diagnosis utama, padahal diabetes penyebabnya sudah diketahui dan ditangani. Aturan MB manakah yang digunakan untuk memperbaikinya?','["MB3","MB4","MB5","MB1","MB2"]','0','Gunakan MB3. Koma adalah gejala atau manifestasi dari diabetes yang sudah diketahui dan ditangani. Karena itu, penyakit penyebab dipilih kembali sebagai diagnosis utama pada contoh ini.'),
('2026-11-23.4','M2-05-2','M2-05','2-coding','Dua keterangan apa yang menunjukkan hubungan koma dengan diabetes dan bahwa diabetes ditangani selama perawatan?','["Dokter mencatat penyakit jantung iskemik, dan pasien dirawat oleh layanan endokrinologi.","Koma ditulis paling awal, dan diabetes ditulis pada kolom diagnosis sekunder.","Diabetes dicatat pada resume, tetapi hubungan dengan koma belum dijelaskan.","Pasien menerima insulin, tetapi penyebab koma tidak disebutkan.","Dokter mengaitkan koma dengan diabetes, dan dosis insulin disesuaikan selama perawatan."]','4','Catatan mengaitkan koma dengan diabetes dan mencatat penentuan dosis insulin selama rawat.'),
('2026-11-23.4','M2-05-3','M2-05','2-coding','Kode E10.0 sudah digunakan untuk diabetes dengan koma. Apakah kode gejala koma masih perlu ditambahkan?','["Tidak. Koma sudah tercakup dalam E10.0.","Ya. R40.2 ditambahkan untuk setiap koma meskipun sudah tercakup dalam kode kombinasi.","Ya. E10.0 hanya menunjukkan jenis diabetes tanpa komplikasinya.","Ya. Koma tetap menjadi diagnosis utama dan E10.0 menjadi diagnosis sekunder.","Tidak. E10.0 diganti dengan R40.2 agar hanya satu kode digunakan."]','0','Koma sudah tercakup dalam E10.0, sehingga tidak perlu diberi kode gejala terpisah.'),
('2026-11-23.4','M2-06-0','M2-06','2-coding','Dokter menulis penyakit jantung kongenital dan defek septum ventrikel untuk kelainan yang sama. Kode apa yang paling spesifik sebagai diagnosis utama?','["Q21.0","Q21.9","Q21.2","Q21.1","Q24.9"]','0','Q21.0 untuk defek septum ventrikel.'),
('2026-11-23.4','M2-06-1','M2-06','2-coding','Diagnosis sekunder menyebut kelainan yang lebih spesifik daripada diagnosis utama, tetapi keduanya merujuk pada kondisi yang sama. Aturan MB manakah yang digunakan?','["MB2","MB3","MB5","MB1","MB4"]','4','Gunakan MB4. Istilah defek septum ventrikel menjelaskan kelainan yang sama secara lebih spesifik daripada istilah umum penyakit jantung kongenital.'),
('2026-11-23.4','M2-06-2','M2-06','2-coding','Dari istilah pada resume, mana yang secara jelas menyebut jenis kelainan pada sekat jantung?','["Penyakit jantung kongenital tanpa rincian.","Diagnosis sekunder pada resume.","Defek septum ventrikel.","Kelainan jantung bawaan tanpa rincian.","Diagnosis utama pada resume."]','2','“Defek septum ventrikel” menyebut lokasi defek secara spesifik.'),
('2026-11-23.4','M2-06-3','M2-06','2-coding','Defek septum ventrikel sudah diberi kode. Apakah istilah umum “penyakit jantung kongenital” untuk kelainan yang sama masih perlu diberi kode terpisah?','["Kedua istilah diberi kode sebagai dua kelainan yang berbeda.","Istilah umum tetap menjadi diagnosis utama; diagnosis spesifik menjadi diagnosis sekunder.","Tidak diberi kode terpisah karena kedua istilah merujuk pada kondisi yang sama.","Istilah umum ditambahkan sebagai diagnosis sekunder untuk kondisi yang sama.","Seluruh pengodean ditunda meskipun diagnosis spesifik sudah tersedia."]','2','Tidak ada kode tambahan untuk sebutan umum karena kedua istilah merujuk pada kondisi yang sama.'),
('2026-11-23.4','M2-07-0','M2-07','2-coding','Dokter menulis “kolesistitis akut atau pankreatitis akut” dan klarifikasi belum berhasil diperoleh. Berdasarkan aturan MB5, kode apa yang dipilih sebagai diagnosis utama?','["K80.0","K81.1","K81.0","K81.9","K85.9"]','2','Pilih K81.0 untuk kolesistitis akut. Pada contoh MB5 ini, kedua penyakit ditulis sebagai alternatif dan klarifikasi belum berhasil; diagnosis yang ditulis pertama dipilih sebagai diagnosis utama.'),
('2026-11-23.4','M2-07-1','M2-07','2-coding','Diagnosis utama ditulis sebagai dua pilihan yang dihubungkan kata “atau”. Aturan MB manakah yang digunakan?','["MB5","MB3","MB2","MB4","MB1"]','0','MB5 mengatur pemilihan diagnosis utama saat dokter menuliskan diagnosis alternatif.'),
('2026-11-23.4','M2-07-2','M2-07','2-coding','Pada catatan “kolesistitis akut atau pankreatitis akut”, bagaimana diagnosis utama dipilih menurut aturan MB5 untuk kasus ini?','["Kata “atau” menandai alternatif; diagnosis yang ditulis pertama dipilih pada contoh ini.","Kata “atau” menandai alternatif; diagnosis yang ditulis terakhir dipilih.","Kedua alternatif dicatat sebagai dua diagnosis utama.","Kedua alternatif diperlakukan sebagai dua kondisi yang pasti ada.","Diagnosis yang namanya lebih umum dipilih tanpa mempertimbangkan urutannya."]','0','Kata “atau” menunjukkan dua pilihan diagnosis, bukan dua penyakit yang dipastikan terjadi bersama. Sesuai aturan MB5 pada contoh ini, pilih diagnosis yang ditulis pertama, yaitu kolesistitis akut.'),
('2026-11-23.4','M2-07-3','M2-07','2-coding','Pankreatitis akut hanya disebut sebagai pilihan setelah kata “atau”. Apakah kondisi itu boleh langsung dicatat sebagai diagnosis sekunder?','["Ya. Setiap diagnosis yang ditulis setelah kata “atau” menjadi diagnosis sekunder.","Ya. Kedua alternatif selalu dianggap sebagai dua penyakit yang terjadi bersamaan.","Tidak. Pankreatitis akut hanya ditulis sebagai alternatif, bukan kondisi sekunder yang dipastikan ada.","Ya. Semua istilah pada kolom diagnosis utama harus diberi kode terpisah.","Ya. Pankreatitis dipilih sebagai diagnosis sekunder karena ditulis terakhir."]','2','Tidak. Dalam pernyataan dokter, pankreatitis akut merupakan alternatif, sehingga belum ditetapkan sebagai diagnosis sekunder.'),
('2026-11-23.4','M2-08-0','M2-08','2-coding','Pada perikarditis tuberkulosa, kode apa yang menunjukkan tuberkulosis sebagai penyakit penyebab?','["A18.0","A18.3","A19.9","I32.0","A18.8"]','4','A18.8 mewakili tuberkulosis sebagai penyakit penyebab dalam pasangan ini.'),
('2026-11-23.4','M2-08-1','M2-08','2-coding','Kode apa yang menunjukkan perikarditis sebagai manifestasi tuberkulosis pada kasus ini?','["A18.8","I32.0","I31.0","I32.1","I30.9"]','1','I32.0 mewakili perikarditis sebagai manifestasi penyakit penyebab.'),
('2026-11-23.4','M2-08-2','M2-08','2-coding','Untuk perikarditis tuberkulosa, pasangan kode dan penempatan diagnosis utama serta sekundernya manakah yang benar?','["Diagnosis utama A18.8 · diagnosis sekunder I32.0","Diagnosis utama I32.0 · diagnosis sekunder A18.8","Diagnosis utama A18.3 · diagnosis sekunder I32.0","Diagnosis utama A18.8 · diagnosis sekunder I32.1","Diagnosis utama A18.8 · diagnosis sekunder I30.9"]','0','A18.8 ditempatkan sebagai diagnosis utama dan I32.0 sebagai diagnosis sekunder.'),
('2026-11-23.4','M2-08-3','M2-08','2-coding','Dokter hanya menulis “perikarditis tuberkulosa”. Mengapa pengodean diagnosis ini tetap membutuhkan dua kode?','["Setiap penyakit infeksi selalu harus menggunakan dua kode.","Satu diagnosis klinis tersebut harus diwakili oleh pasangan kode penyebab dan manifestasi sesuai klasifikasi.","Kolom diagnosis sekunder yang kosong harus diisi dengan satu kode tambahan.","Kode manifestasi menggantikan kode penyebab bila dokter hanya menulis satu diagnosis.","Kode penyebab hanya digunakan jika ada diagnosis tuberkulosis lain."]','1','Perikarditis tuberkulosa diwakili oleh dua kode sesuai klasifikasi: A18.8 untuk penyakit penyebab dan I32.0 untuk manifestasinya pada perikardium. Dua kode ini berasal dari satu diagnosis dokter, bukan dari dua penyakit baru yang ditambahkan koder.'),
('2026-11-23.4','M2-09-0','M2-09','2-coding','Pada laporan A, kraniotomi dilakukan untuk mencapai tumor. Tindakan mana yang kemudian dilakukan untuk menangani tumornya?','["Pembukaan tengkorak saja.","Biopsi tumor saja.","Pencitraan tumor.","Penutupan akses operasi.","Reseksi tumor."]','4','Tindakan untuk menangani tumor pada laporan A adalah reseksi tumor. Kraniotomi dilakukan lebih dahulu untuk mencapai lokasi tumor.'),
('2026-11-23.4','M2-09-1','M2-09','2-coding','Pada laporan A, kraniotomi hanya menjadi jalan masuk untuk reseksi tumor. Apakah kraniotomi perlu diberi kode tersendiri?','["Kraniotomi diberi kode terpisah karena dilakukan lebih dahulu daripada reseksi.","Kraniotomi diberi kode, sedangkan reseksi tumor tidak diberi kode.","Kraniotomi dan reseksi tumor sama-sama tidak diberi kode.","Kraniotomi dicatat sebagai diagnosis sekunder.","Kraniotomi tidak diberi kode terpisah karena merupakan akses menuju reseksi tumor."]','4','Kraniotomi pada laporan A hanya menjadi jalan masuk untuk reseksi tumor. Sesuai petunjuk omit code pada contoh ini, kraniotomi tersebut tidak diberi kode terpisah.'),
('2026-11-23.4','M2-09-2','M2-09','2-coding','Pada laporan B, operasi berhenti setelah kraniotomi tanpa reseksi tumor. Kode apa yang digunakan untuk kraniotomi tersebut?','["02.02","01.23","01.31","01.24","01.51"]','3','Gunakan 01.24. Pada laporan B, tindakan berhenti pada kraniotomi; tidak ada reseksi tumor atau tindakan lanjutan lain.'),
('2026-11-23.4','M2-09-3','M2-09','2-coding','Sebelum memilih kode reseksi tumor pada laporan A, rincian apa yang perlu diperiksa pada laporan operasi lengkap?','["Lama rawat dan kelas perawatan.","Lokasi anatomi tumor dan teknik reseksi pada laporan operasi lengkap.","Nama operator dan nomor kamar operasi.","Waktu mulai anestesi dan lama rawat.","Letak insisi kulit saja."]','1','Telusuri lokasi anatomi tumor dan bagaimana reseksi dilakukan pada laporan operasi yang lengkap.'),
('2026-11-23.4','M4-01-0','M4-01','4','Pasien sudah terintubasi sebelum tiba. Kapan durasi penggunaan ventilator mulai dihitung untuk perawatan di rumah sakit penerima?','["Sejak intubasi pertama di rumah sakit pengirim.","Sejak surat rujukan dibuat.","Sejak masuk rumah sakit penerima, dengan bukti penggunaan ventilator pada episode tersebut.","Sejak pasien meninggalkan rumah sakit pengirim.","Sejak pengajuan administrasi rujukan disetujui."]','2','Durasi untuk rumah sakit penerima dimulai sejak pasien masuk dengan bukti penggunaan ventilator pada perawatan tersebut. Waktu intubasi di rumah sakit pengirim tidak dipakai sebagai awal durasi rumah sakit penerima.'),
('2026-11-23.4','M4-01-1','M4-01','4','Catatan waktu apa yang harus dicocokkan untuk menentukan awal penggunaan ventilator di rumah sakit penerima?','["Waktu intubasi di pengirim dan surat rujukan saja.","Tanggal masuk tanpa jam dan resume pulang saja.","Waktu ekstubasi dan daftar diagnosis saja.","Waktu masuk dan catatan penggunaan ventilator di rumah sakit penerima.","Lama rawat keseluruhan dan jadwal kunjungan dokter."]','3','Cocokkan waktu masuk pasien dengan catatan pemasangan atau penggunaan ventilator di rumah sakit penerima. Kedua catatan diperlukan untuk menentukan awal durasi yang sesuai.'),
('2026-11-23.4','M4-01-2','M4-01','4','Jika rumah sakit penerima kemudian merujuk pasien ke rumah sakit berikutnya, kapan penghitungan durasi ventilasi di rumah sakit penerima dihentikan?','["Saat pasien dipasang ventilator di rumah sakit berikutnya.","Saat pasien terdaftar di rumah sakit berikutnya.","Saat pasien diekstubasi di rumah sakit berikutnya.","Saat ventilator dilepas di rumah sakit penerima sebelum pasien dirujuk lagi.","Saat surat rujukan ke rumah sakit berikutnya diterbitkan."]','3','Jika rumah sakit penerima merujuk pasien lagi, penghitungan untuk rumah sakit penerima berakhir saat ventilator dilepas di rumah sakit tersebut. Jangan meneruskan durasinya sampai penggunaan alat di rumah sakit berikutnya.'),
('2026-11-23.4','M4-01-3','M4-01','4','Ventilasi invasif di rumah sakit penerima berlangsung terus dari 8 November pukul 10.00 sampai 11 November pukul 10.00. Berapa durasi untuk episode rumah sakit penerima?','["48 jam.","74 jam 30 menit.","72 jam.","96 jam.","Tidak bisa dihitung karena intubasi dilakukan di rumah sakit lain."]','2','Selisih 8 November pukul 10.00 hingga 11 November pukul 10.00 adalah 72 jam. Waktu di rumah sakit pengirim tidak ditambahkan pada durasi episode penerima.'),
('2026-11-23.4','M4-02-0','M4-02','4','Agen trombolitik sudah diberikan melalui injeksi atau infus. Kode tindakan apa yang sesuai?','["99.20","99.29","99.19","99.10","99.21"]','3','99.10 untuk injeksi atau infus agen trombolitik.'),
('2026-11-23.4','M4-02-1','M4-02','4','Dokumen apa yang menjadi bukti bahwa agen trombolitik sudah diberikan pada perawatan ini?','["Instruksi awal dokter tanpa catatan pelaksanaan.","Resep obat tanpa konfirmasi pemberian.","Catatan pemberian obat pada episode perawatan sebelumnya.","Daftar obat yang tersedia di farmasi.","Lembar pemberian obat atau catatan pelaksanaan yang membuktikan pemberian pada episode ini."]','4','Gunakan catatan pelaksanaan atau lembar pemberian obat yang menunjukkan tindakan sudah dikerjakan.'),
('2026-11-23.4','M4-02-2','M4-02','4','Pada berkas lain, hanya ada instruksi pemberian trombolitik tanpa catatan bahwa obat sudah diberikan. Apa yang seharusnya dilakukan koder?','["Jangan tetapkan sebagai tindakan terlaksana sebelum ada bukti pemberian.","Tetapkan kode segera berdasarkan instruksi dokter.","Tetapkan kode jika obat sudah dipesan dari farmasi.","Tetapkan kode berdasarkan jadwal pemberian yang direncanakan.","Tetapkan kode jika nama obat muncul pada daftar resep."]','0','Tunda pengodean sampai tersedia bukti bahwa pemberian telah dilakukan.'),
('2026-11-23.4','M4-02-3','M4-02','4','Jika hanya ada catatan pemberian trombolitik tanpa diagnosis akhir dokter, apakah koder boleh menyimpulkan sendiri penyakit pasien?','["Tidak. Diagnosis perlu didasarkan pada penetapan dokter, bukan disimpulkan dari tindakan saja.","Ya. Pemberian trombolitik cukup untuk menetapkan diagnosis stroke tertentu.","Ya. Rute infus menentukan diagnosis penyakitnya.","Ya. Dosis trombolitik dapat digunakan menggantikan diagnosis akhir dokter.","Ya. Nama kelompok obat sudah cukup untuk menetapkan kode diagnosis spesifik."]','0','Tidak. Diagnosis spesifik mengikuti diagnosis yang ditetapkan dokter, sementara catatan pemberian mendukung kode tindakan.'),
('2026-11-23.4','M4-03-0','M4-03','4','Pasien datang untuk kontrol setelah vitrektomi dan tidak menjalani perawatan luka. Kode diagnosis utama apa yang digunakan sesuai kasus pada ICS?','["Z48.8","Z01.0","Z09.0","Z48.0","Z09.9"]','0','Z48.8 digunakan untuk kontrol pascaoperasi mata pada contoh ini.'),
('2026-11-23.4','M4-03-1','M4-03','4','Hipertensi esensial ditulis sebagai diagnosis sekunder. Kode apa yang sesuai?','["I95.9","I15.9","R03.0","I11.9","I10"]','4','I10 untuk hipertensi esensial.'),
('2026-11-23.4','M4-03-2','M4-03','4','Dokter hanya menulis “funduskopi”. Pertanyaan mana yang meminta penjelasan teknik pemeriksaan tanpa menyarankan jawaban tertentu?','["Mohon tuliskan bahwa pemeriksaan dilakukan dengan kamera fundus.","Mohon tuliskan bahwa pemeriksaan dilakukan dengan oftalmoskop.","Mohon gunakan kode foto fundus tanpa menambahkan rincian pemeriksaan.","Mohon jelaskan alat dan teknik pemeriksaan fundus yang digunakan pada kunjungan ini.","Mohon tentukan teknik pemeriksaan dari riwayat vitrektomi saja."]','3','Minta dokter menjelaskan alat dan teknik yang digunakan. Jangan langsung meminta dokter menyebut kamera fundus atau oftalmoskop, karena tekniknya belum diketahui dari catatan.'),
('2026-11-23.4','M4-03-3','M4-03','4','Untuk membedakan teknik pemeriksaan, pasangan kode manakah yang benar untuk foto fundus dan oftalmoskopi?','["Foto fundus 95.12 · oftalmoskopi 16.21","Foto fundus 95.11 · oftalmoskopi 95.12","Foto fundus 95.11 · oftalmoskopi 16.21","Foto fundus 16.21 · oftalmoskopi 95.11","Foto fundus 95.12 · oftalmoskopi 95.11"]','2','Foto fundus dikode 95.11. Oftalmoskopi dikode 16.21.'),
('2026-11-23.4','M4-04-0','M4-04','4','Pada laporan A, lesi telinga luar diangkat untuk terapi. Kode tindakan apa yang sesuai?','["18.31","18.21","18.39","18.12","18.29"]','4','18.29 untuk eksisi lesi telinga luar pada laporan A.'),
('2026-11-23.4','M4-04-1','M4-04','4','Pada laporan B, dokter mengambil sampel jaringan telinga luar untuk biopsi. Kode tindakan apa yang sesuai?','["18.29","18.31","19.0","18.12","18.21"]','3','18.12 untuk biopsi telinga luar pada laporan B.'),
('2026-11-23.4','M4-04-2','M4-04','4','Sampel pada laporan B sudah diperiksa dengan patologi anatomi. Kelompok kode manakah yang perlu diperiksa untuk memilih kode pemeriksaan tersebut?','["91.81","90.89","91.86-","91.85","91.82"]','2','Periksa kelompok 91.86- untuk pemeriksaan patologi anatomi sesuai petunjuk ICS. Tanda hubung berarti kode perlu dilengkapi sesuai rincian pemeriksaan; 91.86- bukan kode akhir untuk langsung dimasukkan.'),
('2026-11-23.4','M4-04-3','M4-04','4','Apa perbedaan tujuan pengambilan jaringan pada laporan A dan laporan B?','["Laporan A: biopsi; laporan B: pengangkatan untuk terapi.","Keduanya biopsi karena lokasi tindakannya sama.","Laporan A: pengangkatan untuk terapi; laporan B: pengambilan sampel untuk biopsi.","Keduanya pengangkatan terapeutik karena sama-sama mengambil jaringan.","Laporan A: pemeriksaan tanpa pengambilan jaringan; laporan B: pengangkatan seluruh lesi."]','2','Pada laporan A, lesi diangkat untuk terapi. Pada laporan B, jaringan diambil untuk diperiksa sebagai biopsi.'),
('2026-11-23.4','M4-05-0','M4-05','4','Untuk TB resistan obat, informasi tambahan apa yang perlu dikodekan selain kode dasar TB sesuai petunjuk ICS?','["Gejala pernapasan dan riwayat penyakit.","Pemeriksaan mikrobiologi dan tindakan radiologi.","Kategori resistansi TB (TB Episode of Care) dan jenis obat terkait resistansi (Drug Types).","Penyebab luar dan cedera.","Pemeriksaan radiologi dan administrasi kunjungan."]','2','ICS meminta penelusuran dua kelompok tambahan: TB Episode of Care untuk kategori resistansi TB, dan Drug Types untuk jenis obat terkait resistansi. Kategori resistansi dan obat yang terlibat harus diperjelas sebelum kode spesifik dipilih.'),
('2026-11-23.4','M4-05-1','M4-05','4','Data mana dalam resume yang menjadi dasar pemilihan kode dasar TB pada kasus ini?','["Riwayat batuk saja.","Foto toraks saja tanpa diagnosis dokter.","Nama layanan TB tanpa lokasi penyakit.","TB paru yang ditetapkan dokter dan dikonfirmasi TCM dahak.","Berat badan turun tanpa pemeriksaan lain."]','3','Lokasi paru ditetapkan dokter dan Mycobacterium tuberculosis terdeteksi pada dahak. Kode dasar TB harus sesuai lokasi dan dasar konfirmasi, kemudian dilengkapi informasi resistansi sesuai ICS.'),
('2026-11-23.4','M4-05-2','M4-05','4','Obat mana yang sudah terbukti resistan pada hasil pemeriksaan pasien ini?','["Isoniazid.","Semua obat TB lini pertama.","Fluorokuinolon.","Rifampisin.","Bedaquiline."]','3','TCM menyatakan resistansi rifampisin terdeteksi. Hasil untuk obat lain belum tersedia; resistansi terhadap obat-obat tersebut tidak boleh diasumsikan.'),
('2026-11-23.4','M4-05-3','M4-05','4','Apakah hasil resistansi rifampisin saja sudah cukup untuk menyimpulkan bahwa pasien pasti mengalami MDR-TB?','["Ya, semua RR-TB pasti resistan terhadap isoniazid.","Belum; resistansi isoniazid perlu diketahui dan kategori akhir mengikuti penetapan dokter.","Ya, penurunan berat badan membuktikan resistansi ganda.","Ya, adanya kavitas membuktikan MDR-TB.","Tidak perlu menilai isoniazid karena semua obat dianggap resistan."]','1','MDR-TB memerlukan resistansi setidaknya terhadap isoniazid dan rifampisin. Kasus ini telah membuktikan RR-TB, sementara hasil isoniazid belum tersedia. Jangan mengubah bukti satu obat menjadi bukti beberapa obat.'),
('2026-11-23.4','M4-06-0','M4-06','4','Dokter sudah melakukan PTCA. Kode tindakan apa yang digunakan?','["36.06","00.63","36.07","00.61","00.66"]','4','00.66 untuk tindakan PTCA.'),
('2026-11-23.4','M4-06-1','M4-06','4','PTCA dilakukan pada satu pembuluh koroner. Kode tambahan apa yang menunjukkan jumlah pembuluh tersebut?','["00.42","00.41","00.40","00.43","00.45"]','2','00.40 menunjukkan tindakan pada satu pembuluh.'),
('2026-11-23.4','M4-06-2','M4-06','4','Dokter memasang satu stent. Kode tambahan apa yang menunjukkan jumlah stent tersebut?','["00.47","00.45","00.48","00.46","00.40"]','1','00.45 menunjukkan jumlah stent yang dipasang, yaitu satu.'),
('2026-11-23.4','M4-06-3','M4-06','4','Jenis stent belum tercantum dalam laporan. Apa yang harus diperiksa atau ditanyakan sebelum memilih kode jenis stent?','["Pilih drug-eluting stent karena hanya satu stent yang dipasang.","Pilih non-drug-eluting stent jika jenisnya belum tertulis.","Tentukan jenis stent dari jumlah pembuluh yang ditangani.","Salin jenis stent dari laporan tindakan pasien lain.","Periksa catatan implan atau minta operator menjelaskan jenis stent yang dipasang."]','4','Periksa kartu atau catatan implan, atau minta operator menjelaskan jenis stent yang dipasang pada episode ini.'),
('2026-11-23.4','M4-07-0','M4-07','4','Pada resume A, dokter menulis apendisitis akut dengan perforasi dan peritonitis umum. Kode diagnosis apa yang sesuai?','["K35.3","K35.8","K36","K37","K35.2"]','4','K35.2 untuk apendisitis akut dengan peritonitis umum.'),
('2026-11-23.4','M4-07-1','M4-07','4','Pada resume B, dokter menulis apendisitis akut dengan peritonitis lokal. Kode diagnosis apa yang sesuai?','["K35.3","K35.8","K37","K36","K35.2"]','0','K35.3 untuk apendisitis akut dengan peritonitis lokal.'),
('2026-11-23.4','M4-07-2','M4-07','4','Istilah apa pada resume A yang menunjukkan bahwa peritonitisnya lebih luas daripada pada resume B?','["Apendisitis akut.","Perforasi tanpa keterangan luas peritonitis.","Peritonitis umum.","Tindakan operasi.","Lokasi apendiks."]','2','Frasa “peritonitis umum” menunjukkan luas peritonitis pada episode A.'),
('2026-11-23.4','M4-07-3','M4-07','4','Kode apendisitis dengan peritonitis umum sudah digunakan pada resume A. Apakah peritonitis masih perlu diberi kode terpisah?','["Ya. Semua peritonitis selalu memerlukan kode terpisah.","Ya. Kode apendisitis hanya menunjukkan lokasi organ.","Ya. Perforasi selalu mengharuskan satu kode peritonitis tambahan.","Tidak. Peritonitis sudah tercakup dalam kode kombinasi yang dipilih.","Tidak. Peritonitis tidak disebut dalam resume A."]','3','Peritonitis umum sudah tercakup dalam kode kombinasi apendisitis akut pada episode A.'),
('2026-11-23.4','M4-08-0','M4-08','4','Dokter berhasil mengeluarkan batu saluran empedu melalui ERCP. Kode tindakan apa yang sesuai?','["51.88","51.87","51.10","51.11","51.85"]','0','51.88 untuk pengangkatan batu dari saluran empedu secara endoskopik pada contoh ini.'),
('2026-11-23.4','M4-08-1','M4-08','4','Pengambilan batu melalui ERCP sudah diberi kode. Apakah 51.10 untuk ERCP diagnostik perlu ditambahkan pada tindakan yang sama?','["Ya. Setiap ERCP terapeutik selalu memerlukan kode ERCP diagnostik tambahan.","Tidak. Pada kasus ini, kode pengambilan batu sudah mencakup pelaksanaan melalui ERCP.","Ya. Judul “ERCP” harus diberi kode terpisah dari uraian tindakan pada sesi yang sama.","Ya. Pengambilan batu dan ERCP pada laporan ini dianggap sebagai dua sesi berbeda.","Tidak. ERCP hanya direncanakan dan belum dilakukan."]','1','Untuk contoh ini, gunakan kode tindakan yang spesifik. Kode ERCP diagnostik 51.10 tidak ditambahkan pada sesi yang sama.'),
('2026-11-23.4','M4-08-2','M4-08','4','Bagian laporan mana yang membuktikan batu sudah dikeluarkan, bukan baru direncanakan untuk dikeluarkan?','["Judul laporan menyebut ERCP.","Diagnosis mencantumkan batu saluran empedu.","Instruksi mencantumkan rencana pengambilan batu.","Jadwal tindakan mencantumkan nama operator.","Uraian operator menyatakan batu berhasil dikeluarkan dari saluran empedu secara endoskopik."]','4','Uraian operator menyatakan bahwa batu telah dikeluarkan dari saluran empedu melalui endoskop.'),
('2026-11-23.4','M4-08-3','M4-08','4','Jika laporan hanya menulis “ERCP”, informasi apa yang masih perlu diperiksa sebelum memberi kode pengambilan batu?','["Lama rawat dan kelas perawatan.","Riwayat pengambilan batu pada episode sebelumnya.","Identitas operator dan nomor ruangan saja.","Biaya tindakan dan jadwal pemeriksaan.","Uraian tindakan yang terlaksana, termasuk lokasi batu dan bukti bahwa batu dikeluarkan."]','4','Periksa uraian prosedur untuk memastikan bahwa pengambilan batu terlaksana dan bahwa batunya berasal dari saluran empedu.'),
('2026-11-23.4','M4-09-0','M4-09','4','Kode tindakan apa yang digunakan untuk artroskopi lutut?','["80.27","80.25","80.26","80.21","81.45"]','2','80.26 untuk artroskopi lutut.'),
('2026-11-23.4','M4-09-1','M4-09','4','Selain artroskopi, dokter melakukan reparasi ligamen krusiat kategori other repair. Kode apa yang sesuai untuk reparasi tersebut?','["80.26","81.47","81.46","81.45","81.44"]','3','Gunakan 81.45 untuk other repair of the cruciate ligaments, yaitu kategori reparasi lain ligamen krusiat sebagaimana dicatat pada laporan.'),
('2026-11-23.4','M4-09-2','M4-09','4','Menurut daftar pada ICS, apakah reparasi ligamen krusiat yang dilakukan bersama artroskopi ini termasuk prosedur kompleks?','["Tidak. Artroskopi dengan reparasi ligamen tetap selalu termasuk prosedur diagnostik.","Tidak. Tindakan pada sendi yang sama tidak boleh dinilai sebagai prosedur kompleks.","Ya. Reparasi tersebut termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.","Ya. Semua artroskopi termasuk kompleks, tanpa melihat tindakan tambahannya.","Tidak. Reparasi hanya dianggap kompleks jika dilakukan pada hari yang berbeda."]','2','Ya. Reparasi yang didokumentasikan termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.'),
('2026-11-23.4','M4-09-3','M4-09','4','Dokumen mana yang membuktikan reparasi ligamen krusiat sudah dilakukan, meskipun judul lembar tindakan hanya menyebut artroskopi?','["Judul laporan yang hanya menulis artroskopi lutut.","Diagnosis yang menyebut keluhan lutut.","Jadwal operasi tanpa catatan pelaksanaan.","Uraian operasi yang menyebut ligamen krusiat dan reparasi yang telah dilakukan.","Formulir persetujuan tindakan tanpa laporan operasi."]','3','Uraian operasi menyebut ligamen yang ditangani dan menyatakan bahwa reparasi dilakukan.'),
('2026-11-23.4','M4-10-0','M4-10','4','Pada laporan A, dokter mengeksisi jaringan luka saat debridemen. Kode tindakan apa yang sesuai?','["86.59","86.22","86.28","86.04","86.09"]','1','86.22 untuk debridemen eksisional pada contoh ini.'),
('2026-11-23.4','M4-10-1','M4-10','4','Pada laporan B, dokter menulis debridemen noneksisional. Kode tindakan apa yang sesuai?','["86.28","86.59","86.09","86.22","86.04"]','0','86.28 untuk debridemen noneksisional.'),
('2026-11-23.4','M4-10-2','M4-10','4','Keterangan mana dalam laporan A yang menunjukkan debridemen dilakukan dengan teknik eksisional?','["Operator mencatat eksisi jaringan luka.","Dokter hanya mencatat lokasi luka.","Jadwal menyebut rencana perawatan luka.","Catatan menyebut pembersihan tanpa eksisi.","Kolom prosedur hanya menulis debridemen tanpa teknik."]','0','Frasa “mengeksisi jaringan luka” menunjukkan teknik eksisional.'),
('2026-11-23.4','M4-10-3','M4-10','4','Pada laporan C, dokter hanya menulis “debridemen”. Apa pertanyaan yang tepat untuk memperjelas tindakan sebelum kode dipilih?','["Mohon nyatakan debridemen eksisional agar kode dapat dipilih.","Mohon nyatakan kedalaman tertentu tanpa memeriksa laporan operasi.","Mohon ganti judul tindakan menjadi debridemen eksisional.","Mohon tentukan kode dari judul tindakan tanpa rincian teknik.","Mohon jelaskan teknik debridemen dan jaringan yang ditangani pada tindakan ini."]','4','Tanyakan teknik debridemen serta jaringan yang ditangani tanpa menyarankan teknik tertentu.'),
('2026-11-23.4','M4-11-0','M4-11','4','Dokter menulis “diabetes melitus tipe 2 dengan ulkus diabetik” pada resume utama. Kode apa yang mencakup diagnosis tersebut sesuai contoh ICS?','["E10.5","E11.9","E11.6","E11.4","E11.5"]','4','E11.5 adalah kode kombinasi yang digunakan untuk diagnosis pada contoh ICS ini.'),
('2026-11-23.4','M4-11-1','M4-11','4','Kata mana pada resume utama yang menunjukkan dokter mengaitkan ulkus dengan diabetes?','["“Diabetes melitus tipe 2” tanpa keterangan komplikasi.","“Ulkus” tanpa keterangan hubungan dengan diabetes.","“Ulkus diabetik”.","Dua diagnosis yang dicatat pada baris terpisah tanpa penjelasan.","Riwayat diabetes saja."]','2','“Ulkus diabetik” menyatakan bahwa dokter mengaitkan ulkus dengan diabetes.'),
('2026-11-23.4','M4-11-2','M4-11','4','Kode untuk diabetes dengan ulkus sudah digunakan. Sesuai contoh ICS ini, apakah ulkus masih perlu diberi kode terpisah?','["Ya. Semua ulkus harus selalu diberi kode terpisah.","Ya. Diabetes harus dikode tanpa komplikasi lalu ditambah kode ulkus.","Tidak. Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi.","Ya. Hubungan diabetes dan ulkus belum dinyatakan pada resume utama.","Tidak. Ulkus hanya merupakan rencana diagnosis."]','2','Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi sehingga tidak dicatat lagi sebagai diagnosis sekunder.'),
('2026-11-23.4','M4-11-3','M4-11','4','Pada resume pembanding, dokter menulis diabetes dan ulkus tanpa menjelaskan kaitannya. Pertanyaan apa yang tepat untuk memperjelas hubungan kedua kondisi?','["Mohon pastikan bahwa ulkus merupakan komplikasi diabetes.","Mohon jelaskan hubungan klinis antara diabetes dan ulkus, bila ada.","Mohon ganti diagnosis ulkus menjadi ulkus diabetik.","Mohon nyatakan bahwa ulkus tidak berkaitan dengan diabetes.","Mohon pilih kode kombinasi tanpa menjelaskan hubungan klinis."]','1','Tanyakan apakah ulkus memiliki hubungan klinis dengan diabetes. Pertanyaan ini meminta penjelasan, tanpa mengarahkan dokter untuk menyatakan bahwa ulkus pasti merupakan komplikasi diabetes.'),
('2026-11-23.4','M6-01-0','M6-01','6','Pada berkas A, dokter belum menulis stadium AKI. Apa pertanyaan yang tepat untuk meminta penjelasan dokter?','["Mohon tetapkan stadium 3 karena ada pemasangan kateter pada berkas lain.","Mohon jelaskan stadium AKI pada episode ini, bila dapat ditentukan secara klinis.","Mohon tetapkan stadium tertinggi untuk mengantisipasi perburukan.","Mohon tetapkan stadium 1 karena belum ada rincian pemeriksaan.","Mohon tentukan stadium hanya dari nama tindakan pada berkas lain."]','1','Minta DPJP menjelaskan stadium AKI bila dapat ditentukan, tanpa mengusulkan salah satu stadium.'),
('2026-11-23.4','M6-01-1','M6-01','6','Kreatinin pasien A meningkat, tetapi DPJP hanya menulis AKI tanpa stadium. Apa langkah yang tepat sebelum memilih kode AKI dengan stadium tertentu?','["Langsung menetapkan stadium tertinggi.","Mengambil stadium dari pasien B.","Meminta DPJP mendokumentasikan atau mengonfirmasi stadium berdasarkan data episode A.","Menganggap semua AKI tanpa stadium sebagai stadium 1.","Mengode berdasarkan pemasangan kateter pada episode B."]','2','Data serial membantu klarifikasi, tetapi koder tidak menetapkan stadium sendiri. Minta penjelasan DPJP secara netral dan gunakan hanya data pasien A. Dokumen pasien B tidak berhubungan dengan episode ini.'),
('2026-11-23.4','M6-01-2','M6-01','6','Pada berkas B, kateter dialisis bertunnel sudah dipasang. Kode tindakan spesifik apa yang digunakan sesuai ICS?','["38.950","39.27","39.95","38.95","54.932"]','0','38.950 sesuai untuk pemasangan tunneled dialysis catheter pada contoh ICS ini.'),
('2026-11-23.4','M6-01-3','M6-01','6','Pada berkas B, kateter dialisis sudah dipasang tetapi tidak ada catatan sesi dialisis. Apakah kode pelaksanaan dialisis boleh langsung ditambahkan?','["Tidak. Pelaksanaan dialisis memerlukan bukti tersendiri, terpisah dari pemasangan akses.","Ya. Pemasangan kateter selalu berarti sesi dialisis sudah selesai.","Ya. Nama kateter yang mengandung kata dialisis sudah cukup sebagai bukti.","Ya. Laporan pemasangan akses menggantikan catatan sesi dialisis.","Ya. Kode pemasangan akses dan kode pelaksanaan dialisis mempunyai arti yang sama."]','0','Pemasangan kateter menyediakan akses dialisis. Hal itu belum membuktikan sesi dialisis sudah dilakukan. Kode pelaksanaan dialisis memerlukan catatan pelaksanaan tersendiri.'),
('2026-11-23.4','M6-02-0','M6-02','6','Ibu mengalami ketuban pecah dini dan mulai bersalin dalam 24 jam. Kode apa yang menjadi diagnosis utama pada berkas ibu?','["O42.0","Z37.0","O80.0","O42.9","O42.1"]','0','O42.0 untuk ketuban pecah dini dengan awal persalinan dalam 24 jam.'),
('2026-11-23.4','M6-02-1','M6-02','6','Untuk persalinan spontan presentasi kepala, kode dan penempatan diagnosis manakah yang benar pada berkas ibu?','["O81.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis utama","O42.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis sekunder","O82.0 sebagai diagnosis sekunder"]','3','O80.0 dicatat sebagai diagnosis sekunder untuk cara persalinan spontan presentasi kepala.'),
('2026-11-23.4','M6-02-2','M6-02','6','Untuk hasil satu bayi lahir hidup, kode dan penempatan diagnosis manakah yang benar pada berkas ibu?','["Z38.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder","Z37.1 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis utama"]','3','Z37.0 dicatat sebagai diagnosis sekunder untuk hasil satu bayi lahir hidup.'),
('2026-11-23.4','M6-02-3','M6-02','6','Persalinan spontan dan episiotomi sudah dilakukan. Pasangan kode tindakan manakah yang sesuai contoh ICS?','["72.1, 73.6","73.59, 72.1","73.59, 73.6","73.4, 73.6","73.59, 75.69"]','2','Gunakan 73.59 dan 73.6. Kode 73.6 adalah kode episiotomi.'),
('2026-11-23.4','M6-03-0','M6-03','6','Dokter menetapkan hipoglikemia neonatal. Kode diagnosis utama apa yang digunakan pada berkas bayi?','["P70.0","P70.4","P70.1","P70.8","P70.9"]','1','P70.4 untuk hipoglikemia neonatal pada contoh ini.'),
('2026-11-23.4','M6-03-1','M6-03','6','Bayi lahir tunggal di rumah sakit. Kode dan penempatan diagnosis manakah yang benar untuk mencatat status kelahirannya?','["Z37.0 sebagai diagnosis sekunder","Z38.1 sebagai diagnosis sekunder","Z38.0 sebagai diagnosis utama","Z37.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder"]','4','Z38.0 dicatat sebagai diagnosis sekunder untuk bayi tunggal yang lahir di rumah sakit.'),
('2026-11-23.4','M6-03-2','M6-03','6','Dua keterangan pada catatan kelahiran mana yang mendasari pemilihan Z38.0?','["Bayi tunggal dan berat lahir 3.000 gram.","Bayi cukup bulan dan berat lahir 3.000 gram.","Hipoglikemia dan hasil pemeriksaan penunjang.","Bayi tunggal dan lahir di rumah sakit.","Bayi cukup bulan dan diagnosis hipoglikemia."]','3','Bayi lahir tunggal dan tempat lahirnya di rumah sakit.'),
('2026-11-23.4','M6-03-3','M6-03','6','Apakah Z37.0 merupakan kode untuk mencatat status kelahiran pada berkas bayi ini?','["Ya. Z37.0 digunakan untuk semua bayi yang lahir di rumah sakit.","Ya. Z37.0 menjadi diagnosis utama untuk hipoglikemia neonatal.","Tidak. Z37.0 digunakan untuk hasil persalinan pada berkas ibu; status kelahiran bayi memakai kategori Z38.","Ya. Z37.0 menggantikan kode status kelahiran bayi.","Tidak. Status kelahiran bayi tidak perlu dicatat meskipun tersedia pada sumber."]','2','Z37.0 mencatat hasil persalinan pada episode ibu. Pada episode bayi, status kelahiran dicatat dengan kode yang sesuai dari kategori Z38.'),
('2026-11-23.4','M6-04-0','M6-04','6','Pasien masuk karena pielonefritis akut, lalu mengalami sepsis selama dirawat. Sesuai urutan kejadian pada contoh ICS ini, kode apa yang menjadi diagnosis utama?','["N39.0","A41.5","N11.9","N10","N12"]','3','N10 untuk pielonefritis akut sebagai diagnosis utama pada episode ini.'),
('2026-11-23.4','M6-04-1','M6-04','6','Kode diagnosis sekunder apa yang digunakan untuk sepsis akibat E. coli sesuai contoh ICS ini?','["A41.0","A41.8","A40.9","A41.5","A41.9"]','3','A41.5 untuk sepsis akibat organisme Gram-negatif lain, sebagaimana digunakan pada contoh ICS ini.'),
('2026-11-23.4','M6-04-2','M6-04','6','Kode tambahan apa yang menunjukkan E. coli sebagai penyebab pielonefritis?','["B96.8","B96.5","B96.2","B96.1","B95.6"]','2','B96.2 mencatat E. coli sebagai organisme penyebab.'),
('2026-11-23.4','M6-04-3','M6-04','6','Catatan mana yang menunjukkan bahwa dokter sudah menetapkan diagnosis sepsis, bukan hanya menemukan kultur positif?','["Kultur darah positif tanpa diagnosis sepsis dari dokter.","Demam dan menggigil saja.","DPJP secara jelas menuliskan diagnosis “sepsis akibat E. coli”.","Tekanan darah 120/70 mmHg saja.","Kultur urin positif tanpa penetapan diagnosis sepsis."]','2','DPJP secara eksplisit menetapkan “sepsis akibat E. coli”. Kultur positif membantu mengidentifikasi organisme dan harus dibaca bersama diagnosis dokter.'),
('2026-11-23.4','M6-05-0','M6-05','6','Dokter menetapkan cedera organ dalam dada sebagai kondisi utama dan fraktur terbuka humerus sebagai kondisi lain. Pasangan kode diagnosis utama dan sekunder manakah yang sesuai?','["Diagnosis utama S42.21 · diagnosis sekunder S27.7","Diagnosis utama S27.7 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.31","Diagnosis utama S27.9 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.20"]','1','S27.7 menjadi diagnosis utama untuk cedera multipel organ intratorakal. S42.21 menjadi diagnosis sekunder untuk fraktur terbuka humerus proksimal dalam contoh ini.'),
('2026-11-23.4','M6-05-1','M6-05','6','Pasien mengemudikan mobil yang menabrak pohon. Kode penyebab luar apa yang digunakan sesuai contoh ICS?','["V49.9","V47.59","V89.2","V47.69","V47.09"]','1','V47.59 adalah kode penyebab luar yang digunakan pada contoh ICS ini.'),
('2026-11-23.4','M6-05-2','M6-05','6','WSD pada dada dan ORIF pada humerus sudah dilakukan. Pasangan kode tindakan manakah yang sesuai contoh ICS?','["WSD 34.04 · ORIF 79.31","WSD 34.04 · ORIF 79.19","WSD 79.39 · ORIF 34.04","WSD 34.04 · ORIF 79.39","WSD 34.91 · ORIF 79.39"]','3','WSD dikode 34.04 dan ORIF humerus dikode 79.39.'),
('2026-11-23.4','M6-05-3','M6-05','6','Cedera pada dada dan humerus termasuk dalam dua kelompok lokasi tubuh yang mana saat menelaah kriteria MDC 31?','["Dada dan ekstremitas atas","Abdomen dan ekstremitas atas","Pelvis dan ekstremitas atas","Kepala dan dada","Dada dan ekstremitas bawah"]','0','Lokasi cedera adalah dada dan ekstremitas atas atau anggota gerak atas. Humerus termasuk ekstremitas atas. Informasi lokasi ini digunakan untuk menelaah kriteria trauma; penetapan MDC tetap mengikuti kriteria grouper.'),
('2026-11-23.4','M6-06-0','M6-06','6','Pasien datang khusus untuk menjalani terapi rehabilitasi. Kode diagnosis utama apa yang sesuai untuk kunjungan ini?','["Z50.8","Z50.0","Z50.1","Z51.8","M54.5"]','2','Z50.1 untuk kunjungan terapi fisik pada contoh ini.'),
('2026-11-23.4','M6-06-1','M6-06','6','Rehabilitasi diberikan karena nyeri punggung bawah. Kode diagnosis sekunder apa yang digunakan sesuai contoh ICS?','["Z50.1","M54.5","M54.4","M54.6","M54.9"]','1','M54.5 adalah kode nyeri punggung bawah yang digunakan pada contoh ini.'),
('2026-11-23.4','M6-06-2','M6-06','6','Peregangan sudah dilakukan. Kode tindakan apa yang sesuai?','["93.27","93.11","93.28","93.35","93.12"]','0','93.27 untuk peregangan pada contoh ini.'),
('2026-11-23.4','M6-06-3','M6-06','6','Terapi inframerah sudah dilakukan. Kode tindakan apa yang sesuai?','["93.32","93.27","93.35","93.34","93.39"]','2','93.35 untuk terapi inframerah pada contoh ini.'),
('2026-11-23.4','M6-07-0','M6-07','6','Terapi whirlpool sudah diberikan, tetapi aplikasi menampilkan “rehabilitasi tanpa prosedur”. Apa kesalahan pada isian aplikasi?','["Kode prosedur whirlpool belum diisi meskipun terapi sudah dilaksanakan.","Kode diagnosis utama belum diisi.","Kode diagnosis sekunder belum diisi.","Terapi whirlpool belum dilaksanakan karena hasil grouper menyebut tanpa prosedur.","Kode hasil grouper sudah menjadi pengganti kode prosedur whirlpool."]','0','Catatan terapi menyatakan whirlpool sudah diberikan, tetapi kolom tindakan belum diisi. Petugas perlu memasukkan kode tindakan yang sesuai, bukan menganggap terapi tidak dilakukan hanya karena uraian hasil grouping.'),
('2026-11-23.4','M6-07-1','M6-07','6','Kode tindakan apa yang harus dimasukkan untuk terapi whirlpool yang sudah diberikan?','["93.35","93.31","93.33","93.39","93.32"]','4','93.32 untuk terapi whirlpool.'),
('2026-11-23.4','M6-07-2','M6-07','6','Kode whirlpool sudah ditambahkan. Apa langkah berikutnya pada aplikasi grouper?','["Gunakan hasil lama dan cukup ubah uraiannya.","Validasi kembali isian yang diperbarui, lalu jalankan pengelompokan ulang.","Catat kode prosedur tanpa menjalankan pengelompokan ulang.","Jalankan pengelompokan ulang sebelum memasukkan kode prosedur.","Ubah diagnosis utama tanpa memeriksa catatan terapi."]','1','Periksa dan validasi kembali isian yang sudah ditambahkan, lalu jalankan grouping ulang. Hasil sebelum perbaikan tidak digunakan sebagai hasil akhir setelah isian berubah.'),
('2026-11-23.4','M6-07-3','M6-07','6','Setelah grouping dijalankan ulang, hasil apa yang harus diperiksa dan dicatat petugas?','["Pertahankan kode dan uraian hasil lama tanpa memeriksa hasil baru.","Periksa apakah keluaran lama sudah berubah, lalu catat kode dan uraian yang benar-benar muncul setelah pengelompokan ulang.","Catat kode hasil yang diperkirakan muncul meskipun aplikasi belum dijalankan ulang.","Catat kode prosedur saja tanpa meninjau hasil pengelompokan.","Nyatakan koreksi berhasil hanya karena kolom prosedur sudah terisi."]','1','Baca hasil grouping yang baru, periksa apakah masalah “rehabilitasi tanpa prosedur” sudah teratasi, lalu catat kode dan uraian yang benar-benar tampil. Jangan menebak kode hasil setelah perbaikan.'),
('2026-11-23.4','M6-08-0','M6-08','6','Pada laporan A, pasien sudah menjalani CT kepala. Kode pemeriksaan apa yang sesuai?','["87.04","88.38","87.02","87.03","88.91"]','3','87.03 untuk CT kepala.'),
('2026-11-23.4','M6-08-1','M6-08','6','Pada laporan B, pasien sudah menjalani MRI kepala. Kode pemeriksaan apa yang sesuai?','["88.97","87.03","88.91","88.93","88.92"]','2','88.91 untuk MRI otak dan batang otak pada contoh ICS ini.'),
('2026-11-23.4','M6-08-2','M6-08','6','Bahan kontras sudah diberikan pada CT kepala dalam laporan A. Kode tambahan apa yang digunakan sesuai ICS?','["99.10","99.290","99.21","99.20","99.250"]','1','99.290 menunjukkan pemberian bahan kontras pada pemeriksaan CT yang tercatat.'),
('2026-11-23.4','M6-08-3','M6-08','6','Bahan kontras sudah diberikan pada MRI kepala dalam laporan B. Kode tambahan apa yang digunakan sesuai ICS?','["99.290","99.10","99.21","99.250","99.20"]','0','99.290 juga digunakan untuk pemberian bahan kontras pada pemeriksaan MRI yang tercatat.')
on conflict(revision,item_id) do nothing;
commit;

begin;
insert into idrg_private.bank_versions(revision,active) values('2026-11-24.1',false) on conflict(revision) do nothing;
insert into idrg_private.questions(revision,item_id,case_id,packet_id,prompt,options,correct,feedback) values
('2026-11-24.1','M2-01-0','M2-01','2-casemix','Petugas memasukkan kode ICD diagnosis dan tindakan, lalu menjalankan grouping. Hasilnya adalah grup iDRG 2401210. Berapa MDC dan Base DC pada grup tersebut?','["MDC 24 · Base DC 2410","MDC 24 · Base DC 24012","MDC 20 · Base DC 2001","MDC 21 · Base DC 2101","MDC 24 · Base DC 2401"]','4','MDC adalah dua digit pertama, yaitu 24. Base DC adalah empat digit pertama, yaitu 2401. Keduanya dibaca dari grup iDRG 2401210.'),
('2026-11-24.1','M2-01-1','M2-01','2-casemix','Pada grup iDRG 2401210, berapa DC lengkap dan nilai split-nya?','["DC 24012 · split 1","DC 24021 · split 1","DC 24012 · split 2","DC 2401210 · split 2","DC 24010 · split 0"]','2','DC lengkap adalah lima digit pertama, yaitu 24012. Angka kelima adalah 2; angka ini merupakan split atau pembeda kelompok pada kode tersebut.'),
('2026-11-24.1','M2-01-2','M2-01','2-casemix','Apa arti digit keenam (PTD 1) dan ketujuh (CL 0) pada grup iDRG 2401210?','["PTD 1 rawat jalan dan CL 0 Mild CC","PTD 1 rawat jalan dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Mild CC","PTD 1 rawat inap dan CL 0 No CC","PTD 1 rawat inap dan CL 0 Severe CC"]','3','Pada grup ini, PTD 1 menunjukkan rawat inap. CL 0 menunjukkan No CC, yaitu tanpa komplikasi atau komorbiditas pada tingkat kelompok ini.'),
('2026-11-24.1','M2-01-3','M2-01','2-casemix','Apa fungsi kode ICD diagnosis dan tindakan yang dimasukkan sebelum grouping?','["Pesan kesalahan dari aplikasi.","Kode diagnosis utama yang dihasilkan aplikasi.","Kode tindakan yang dihasilkan aplikasi.","Hasil akhir pengelompokan iDRG.","Data masukan untuk pengelompokan iDRG."]','4','Kode ICD diagnosis dan tindakan adalah data masukan. Petugas memasukkan data tersebut lebih dahulu, kemudian aplikasi memprosesnya dan menghasilkan grup iDRG 2401210.'),
('2026-11-24.1','M2-02-0','M2-02','2-casemix','Apa kode diagnosis utama pada perawatan ibu ini?','["Z37.0","O42.9","O80.0","O42.0","O42.1"]','3','Ketuban pecah dini menjadi alasan ibu datang dan dirawat. Karena persalinan dimulai dalam 24 jam, diagnosis utama pada kasus ini adalah O42.0.'),
('2026-11-24.1','M2-02-1','M2-02','2-casemix','Jika O42.0 menjadi diagnosis utama, pasangan kode mana yang digunakan sebagai diagnosis sekunder pada berkas ibu?','["O80.0, Z38.0","O42.0, Z37.0","O80.0, Z37.0","O42.0, O80.0","O82.0, Z37.0"]','2','Gunakan O80.0 untuk cara persalinan spontan presentasi kepala dan Z37.0 untuk hasil kelahiran satu bayi hidup.'),
('2026-11-24.1','M2-02-2','M2-02','2-casemix','Petugas baru memasukkan tindakan 73.59. Kode apa yang perlu ditambahkan untuk episiotomi?','["73.59","72.1","73.6","73.4","75.69"]','2','Tambahkan 73.6 karena catatan persalinan menyebut episiotomi sudah dilakukan.'),
('2026-11-24.1','M2-02-3','M2-02','2-casemix','Setelah kode diperbaiki, apa langkah berikutnya sebelum hasil grouping dicatat?','["Jalankan grouper, salin hasilnya, lalu koreksi isian tanpa pengelompokan ulang.","Validasi isian, selesaikan ketidaksesuaian, jalankan grouper, lalu catat kode dan uraian dari hasil yang sama.","Koreksi diagnosis, lalu gunakan kode dan uraian hasil pengelompokan sebelumnya.","Validasi isian, lalu salin kode hasil baru dan uraian dari kasus lain dengan diagnosis serupa.","Catat kode serta uraian dari draf sebelum isian divalidasi."]','1','Periksa kembali isian yang sudah diperbaiki dan selesaikan pesan ketidaksesuaian. Jalankan grouping, lalu catat kode grup beserta uraiannya dari hasil yang sama.'),
('2026-11-24.1','M2-03-0','M2-03','2-coding','Sinusitis akut tertulis sebagai diagnosis utama. Permintaan klarifikasi kepada DPJP belum terjawab. Apa kode diagnosis utama hasil reseleksi berdasarkan perawatan yang diberikan?','["D06.0","C54.1","C53.0","C53.9","C53.1"]','2','Pilih C53.0 untuk karsinoma endoserviks. Pasien menjalani histerektomi total dan dirawat di layanan ginekologi. Pada contoh ini, setelah klarifikasi tidak berhasil, kedua catatan tersebut mendukung pemilihan kembali diagnosis utama dengan MB1.'),
('2026-11-24.1','M2-03-1','M2-03','2-coding','Aturan MB mana yang digunakan ketika kondisi yang lebih berperan dalam perawatan justru tertulis sebagai diagnosis sekunder?','["MB5","MB3","MB2","MB1","MB4"]','3','Gunakan MB1. Pada kasus ini, kondisi yang lebih berperan dalam perawatan ditulis sebagai diagnosis sekunder, sedangkan sinusitis akut ditulis sebagai diagnosis utama. Klarifikasi dokter sudah diupayakan tetapi belum berhasil.'),
('2026-11-24.1','M2-03-2','M2-03','2-coding','Informasi mana yang mendukung reseleksi karsinoma endoserviks sebagai diagnosis utama?','["Hipertensi dan lama perawatan tiga minggu.","Sinusitis akut dan posisinya sebagai diagnosis utama pada draf.","Histerektomi total dan perawatan di layanan ginekologi.","Hipertensi dan urutan penulisannya pada resume.","Lama perawatan dan urutan diagnosis pada draf."]','2','Histerektomi total dan perawatan di layanan ginekologi mendukung bahwa perawatan berfokus pada kondisi ginekologi.'),
('2026-11-24.1','M2-03-3','M2-03','2-coding','Setelah karsinoma endoserviks dipilih sebagai diagnosis utama, dua penyakit mana yang menjadi diagnosis sekunder?','["Hipertensi saja","Karsinoma endoserviks dan hipertensi","Sinusitis akut dan karsinoma endoserviks","Sinusitis akut dan hipertensi","Sinusitis akut saja"]','3','Sinusitis akut dan hipertensi menempati diagnosis sekunder pada kasus ini.'),
('2026-11-24.1','M2-04-0','M2-04','2-coding','Dokter menulis tiga penyakit sebagai diagnosis utama dan belum menjawab klarifikasi. Berdasarkan fokus pemeriksaan dan pengobatan, apa kode diagnosis utama yang dipilih?','["G00.3","G00.1","G00.9","G00.2","G03.9"]','0','G00.3 mewakili meningitis stafilokokus. Resume menulis beberapa diagnosis sebagai utama; pada MB2, fokus pemeriksaan dan pengobatan membantu memilih satu kondisi. Meningitis mendapat evaluasi cairan serebrospinal, kultur, antibiotik, dan pemantauan neurologis. Spesialisasi layanan saja bukan satu-satunya dasar.'),
('2026-11-24.1','M2-04-1','M2-04','2-coding','Aturan MB mana yang digunakan untuk memilih satu diagnosis utama ketika dokter menulis beberapa penyakit pada kolom diagnosis utama?','["MB4","MB2","MB3","MB1","MB5"]','1','MB2 digunakan untuk memilih satu diagnosis utama ketika beberapa kondisi ditulis sebagai diagnosis utama.'),
('2026-11-24.1','M2-04-2','M2-04','2-coding','Informasi mana yang paling kuat menunjukkan penyakit yang menjadi fokus perawatan?','["Katarak ditulis paling awal.","Kolom diagnosis sekunder kosong.","Jumlah diagnosis pada resume ada tiga.","Lama rawat lima minggu saja.","Pemeriksaan cairan serebrospinal, kultur, dan terapi infeksi sistem saraf."]','4','Pada MB2, penentuan didasarkan pada kondisi yang terutama diperiksa atau diobati. Dokumentasi pemeriksaan dan terapi meningitis lebih kuat daripada urutan tulisan, lama rawat, atau nama layanan semata.'),
('2026-11-24.1','M2-04-3','M2-04','2-coding','Setelah meningitis stafilokokus dipilih sebagai diagnosis utama, dua penyakit mana yang menjadi diagnosis sekunder?','["Meningitis stafilokokus dan penyakit jantung iskemik","Penyakit jantung iskemik saja","Katarak saja","Katarak dan penyakit jantung iskemik","Katarak dan meningitis stafilokokus"]','3','Katarak dan penyakit jantung iskemik menjadi diagnosis sekunder pada kasus ini.'),
('2026-11-24.1','M2-05-0','M2-05','2-coding','DPJP menyatakan koma disebabkan oleh diabetes melitus tipe 1. Apa kode diagnosis utama yang mencakup diabetes dengan koma?','["R40.2","E10.1","E10.0","E10.9","E11.0"]','2','E10.0 mencakup diabetes melitus dependen insulin dengan koma dalam satu kode. Dokter sudah mengaitkan koma dengan diabetes, dan diabetes mendapat penanganan selama perawatan.'),
('2026-11-24.1','M2-05-1','M2-05','2-coding','Dokter menulis koma sebagai diagnosis utama, sementara penyakit penyebabnya sudah diketahui dan ditangani. Aturan MB mana yang digunakan untuk reseleksi?','["MB3","MB4","MB5","MB1","MB2"]','0','Gunakan MB3. Koma adalah gejala atau manifestasi dari diabetes yang sudah diketahui dan ditangani. Karena itu, penyakit penyebab dipilih kembali sebagai diagnosis utama pada kasus ini.'),
('2026-11-24.1','M2-05-2','M2-05','2-coding','Informasi mana yang mendukung bahwa koma disebabkan oleh diabetes dan diabetes ditangani selama rawat?','["Dokter mencatat penyakit jantung iskemik, dan pasien dirawat oleh layanan endokrinologi.","Koma ditulis paling awal, dan diabetes ditulis pada kolom diagnosis sekunder.","Diabetes dicatat pada resume, tetapi hubungan dengan koma belum dijelaskan.","Pasien menerima insulin, tetapi penyebab koma tidak disebutkan.","Dokter mengaitkan koma dengan diabetes, dan dosis insulin disesuaikan selama perawatan."]','4','Catatan mengaitkan koma dengan diabetes dan mencatat penentuan dosis insulin selama rawat.'),
('2026-11-24.1','M2-05-3','M2-05','2-coding','Jika diabetes dengan koma sudah dikode E10.0, apakah kode gejala koma perlu ditambahkan?','["Tidak. Koma sudah tercakup dalam E10.0.","Ya. R40.2 ditambahkan untuk setiap koma meskipun sudah tercakup dalam kode kombinasi.","Ya. E10.0 hanya menunjukkan jenis diabetes tanpa komplikasinya.","Ya. Koma tetap menjadi diagnosis utama dan E10.0 menjadi diagnosis sekunder.","Tidak. E10.0 diganti dengan R40.2 agar hanya satu kode digunakan."]','0','Koma sudah tercakup dalam E10.0, sehingga tidak perlu diberi kode gejala terpisah.'),
('2026-11-24.1','M2-06-0','M2-06','2-coding','Istilah penyakit jantung kongenital dan defek septum ventrikel merujuk pada kelainan yang sama. Apa kode diagnosis utama yang paling spesifik?','["Q21.0","Q21.9","Q21.2","Q21.1","Q24.9"]','0','Q21.0 untuk defek septum ventrikel.'),
('2026-11-24.1','M2-06-1','M2-06','2-coding','Diagnosis sekunder menjelaskan diagnosis utama secara lebih spesifik, dan keduanya merupakan kondisi yang sama. Aturan MB mana yang digunakan?','["MB2","MB3","MB5","MB1","MB4"]','4','Gunakan MB4. Istilah defek septum ventrikel menjelaskan kelainan yang sama secara lebih spesifik daripada istilah umum penyakit jantung kongenital.'),
('2026-11-24.1','M2-06-2','M2-06','2-coding','Istilah mana pada resume yang menyebut kelainan anatomi jantung secara spesifik?','["Penyakit jantung kongenital tanpa rincian.","Diagnosis sekunder pada resume.","Defek septum ventrikel.","Kelainan jantung bawaan tanpa rincian.","Diagnosis utama pada resume."]','2','“Defek septum ventrikel” menyebut lokasi defek secara spesifik.'),
('2026-11-24.1','M2-06-3','M2-06','2-coding','Setelah defek septum ventrikel dikode, apakah istilah umum penyakit jantung kongenital perlu dikode lagi sebagai penyakit terpisah?','["Kedua istilah diberi kode sebagai dua kelainan yang berbeda.","Istilah umum tetap menjadi diagnosis utama; diagnosis spesifik menjadi diagnosis sekunder.","Tidak diberi kode terpisah karena kedua istilah merujuk pada kondisi yang sama.","Istilah umum ditambahkan sebagai diagnosis sekunder untuk kondisi yang sama.","Seluruh pengodean ditunda meskipun diagnosis spesifik sudah tersedia."]','2','Tidak ada kode tambahan untuk sebutan umum karena kedua istilah merujuk pada kondisi yang sama.'),
('2026-11-24.1','M2-07-0','M2-07','2-coding','Pada diagnosis akhir tertulis “kolesistitis akut atau pankreatitis akut”. Klarifikasi kepada DPJP belum terjawab. Apa kode diagnosis utama yang dipilih?','["K80.0","K81.1","K81.0","K81.9","K85.9"]','2','Pilih K81.0 untuk kolesistitis akut. Pada contoh MB5 ini, kedua penyakit ditulis sebagai alternatif dan klarifikasi belum berhasil; diagnosis yang ditulis pertama dipilih sebagai diagnosis utama.'),
('2026-11-24.1','M2-07-1','M2-07','2-coding','Aturan MB mana yang digunakan untuk dua diagnosis alternatif yang dihubungkan dengan kata “atau”?','["MB5","MB3","MB2","MB4","MB1"]','0','MB5 mengatur pemilihan diagnosis utama saat dokter menuliskan diagnosis alternatif.'),
('2026-11-24.1','M2-07-2','M2-07','2-coding','Bagaimana memilih diagnosis utama dari pernyataan “kolesistitis akut atau pankreatitis akut” ketika klarifikasi belum terjawab?','["Kata “atau” menandai alternatif; diagnosis yang ditulis pertama dipilih pada kasus ini.","Kata “atau” menandai alternatif; diagnosis yang ditulis terakhir dipilih.","Kedua alternatif dicatat sebagai dua diagnosis utama.","Kedua alternatif diperlakukan sebagai dua kondisi yang pasti ada.","Diagnosis yang namanya lebih umum dipilih tanpa mempertimbangkan urutannya."]','0','Kata “atau” menunjukkan dua pilihan diagnosis, bukan dua penyakit yang dipastikan terjadi bersama. Sesuai aturan MB5 pada kasus ini, pilih diagnosis yang ditulis pertama, yaitu kolesistitis akut.'),
('2026-11-24.1','M2-07-3','M2-07','2-coding','Apakah pankreatitis akut yang hanya tertulis sebagai alternatif boleh langsung dimasukkan sebagai diagnosis sekunder?','["Ya. Setiap diagnosis yang ditulis setelah kata “atau” menjadi diagnosis sekunder.","Ya. Kedua alternatif selalu dianggap sebagai dua penyakit yang terjadi bersamaan.","Tidak. Pankreatitis akut hanya ditulis sebagai alternatif, bukan kondisi sekunder yang dipastikan ada.","Ya. Semua istilah pada kolom diagnosis utama harus diberi kode terpisah.","Ya. Pankreatitis dipilih sebagai diagnosis sekunder karena ditulis terakhir."]','2','Tidak. Dalam pernyataan dokter, pankreatitis akut merupakan alternatif, sehingga belum ditetapkan sebagai diagnosis sekunder.'),
('2026-11-24.1','M2-08-0','M2-08','2-coding','Apa kode untuk tuberkulosis sebagai penyebab perikarditis pada pasien ini?','["A18.0","A18.3","A19.9","I32.0","A18.8"]','4','A18.8 mewakili tuberkulosis sebagai penyakit penyebab dalam pasangan ini.'),
('2026-11-24.1','M2-08-1','M2-08','2-coding','Apa kode untuk manifestasi perikarditis akibat tuberkulosis?','["A18.8","I32.0","I31.0","I32.1","I30.9"]','1','I32.0 mewakili perikarditis sebagai manifestasi penyakit penyebab.'),
('2026-11-24.1','M2-08-2','M2-08','2-coding','Pasangan kode dan urutan diagnosis mana yang tepat untuk perikarditis tuberkulosa?','["Diagnosis utama A18.8 · diagnosis sekunder I32.0","Diagnosis utama I32.0 · diagnosis sekunder A18.8","Diagnosis utama A18.3 · diagnosis sekunder I32.0","Diagnosis utama A18.8 · diagnosis sekunder I32.1","Diagnosis utama A18.8 · diagnosis sekunder I30.9"]','0','A18.8 ditempatkan sebagai diagnosis utama dan I32.0 sebagai diagnosis sekunder.'),
('2026-11-24.1','M2-08-3','M2-08','2-coding','Mengapa diagnosis perikarditis tuberkulosa memerlukan dua kode meskipun dokter hanya menulis satu diagnosis?','["Setiap penyakit infeksi selalu harus menggunakan dua kode.","Satu diagnosis klinis tersebut harus diwakili oleh pasangan kode penyebab dan manifestasi sesuai klasifikasi.","Kolom diagnosis sekunder yang kosong harus diisi dengan satu kode tambahan.","Kode manifestasi menggantikan kode penyebab bila dokter hanya menulis satu diagnosis.","Kode penyebab hanya digunakan jika ada diagnosis tuberkulosis lain."]','1','Perikarditis tuberkulosa diwakili oleh dua kode sesuai klasifikasi: A18.8 untuk penyakit penyebab dan I32.0 untuk manifestasinya pada perikardium. Dua kode ini berasal dari satu diagnosis dokter, bukan dari dua penyakit baru yang ditambahkan koder.'),
('2026-11-24.1','M2-09-0','M2-09','2-coding','Pada pasien A, tindakan apa yang dilakukan untuk menangani tumor setelah kraniotomi?','["Pembukaan tengkorak saja.","Biopsi tumor saja.","Pencitraan tumor.","Penutupan akses operasi.","Reseksi tumor."]','4','Tindakan untuk menangani tumor pada laporan A adalah reseksi tumor. Kraniotomi dilakukan lebih dahulu untuk mencapai lokasi tumor.'),
('2026-11-24.1','M2-09-1','M2-09','2-coding','Pada pasien A, apakah kraniotomi sebagai akses menuju reseksi tumor perlu dikode terpisah?','["Kraniotomi diberi kode terpisah karena dilakukan lebih dahulu daripada reseksi.","Kraniotomi diberi kode, sedangkan reseksi tumor tidak diberi kode.","Kraniotomi dan reseksi tumor sama-sama tidak diberi kode.","Kraniotomi dicatat sebagai diagnosis sekunder.","Kraniotomi tidak diberi kode terpisah karena merupakan akses menuju reseksi tumor."]','4','Kraniotomi pada laporan A hanya menjadi jalan masuk untuk reseksi tumor. Sesuai petunjuk omit code pada kasus ini, kraniotomi tersebut tidak diberi kode terpisah.'),
('2026-11-24.1','M2-09-2','M2-09','2-coding','Pada pasien B, operasi dihentikan setelah kraniotomi dan tumor belum direseksi. Apa kode tindakan yang sudah dilakukan?','["02.02","01.23","01.31","01.24","01.51"]','3','Gunakan 01.24. Pada laporan B, tindakan berhenti pada kraniotomi; tidak ada reseksi tumor atau tindakan lanjutan lain.'),
('2026-11-24.1','M2-09-3','M2-09','2-coding','Rincian apa pada laporan operasi pasien A yang harus dicocokkan sebelum menentukan kode reseksi tumor?','["Lama rawat dan kelas perawatan.","Lokasi anatomi tumor dan teknik reseksi pada laporan operasi lengkap.","Nama operator dan nomor kamar operasi.","Waktu mulai anestesi dan lama rawat.","Letak insisi kulit saja."]','1','Telusuri lokasi anatomi tumor dan bagaimana reseksi dilakukan pada laporan operasi yang lengkap.'),
('2026-11-24.1','M4-01-0','M4-01','4','Pasien tiba dalam keadaan terintubasi dan langsung melanjutkan ventilasi invasif. Kapan penghitungan durasi ventilasi di rumah sakit penerima dimulai?','["Sejak intubasi pertama di rumah sakit pengirim.","Sejak surat rujukan dibuat.","Sejak masuk rumah sakit penerima, dengan bukti penggunaan ventilator pada episode tersebut.","Sejak pasien meninggalkan rumah sakit pengirim.","Sejak pengajuan administrasi rujukan disetujui."]','2','Durasi untuk rumah sakit penerima dimulai sejak pasien masuk dengan bukti penggunaan ventilator pada perawatan tersebut. Waktu intubasi di rumah sakit pengirim tidak dipakai sebagai awal durasi rumah sakit penerima.'),
('2026-11-24.1','M4-01-1','M4-01','4','Dua catatan waktu mana yang harus dicocokkan untuk menentukan awal ventilasi di rumah sakit penerima?','["Waktu intubasi di pengirim dan surat rujukan saja.","Tanggal masuk tanpa jam dan resume pulang saja.","Waktu ekstubasi dan daftar diagnosis saja.","Waktu masuk dan catatan penggunaan ventilator di rumah sakit penerima.","Lama rawat keseluruhan dan jadwal kunjungan dokter."]','3','Cocokkan waktu masuk pasien dengan catatan pemasangan atau penggunaan ventilator di rumah sakit penerima. Kedua catatan diperlukan untuk menentukan awal durasi yang sesuai.'),
('2026-11-24.1','M4-01-2','M4-01','4','Jika pasien dirujuk lagi ke rumah sakit lain, kapan penghitungan durasi ventilasi di rumah sakit penerima dihentikan?','["Saat pasien dipasang ventilator di rumah sakit berikutnya.","Saat pasien terdaftar di rumah sakit berikutnya.","Saat pasien diekstubasi di rumah sakit berikutnya.","Saat ventilator dilepas di rumah sakit penerima sebelum pasien dirujuk lagi.","Saat surat rujukan ke rumah sakit berikutnya diterbitkan."]','3','Jika rumah sakit penerima merujuk pasien lagi, penghitungan untuk rumah sakit penerima berakhir saat ventilator dilepas di rumah sakit tersebut. Jangan meneruskan durasinya sampai penggunaan alat di rumah sakit berikutnya.'),
('2026-11-24.1','M4-01-3','M4-01','4','Ventilasi invasif berlangsung tanpa jeda dari 8 November pukul 10.00 sampai 11 November pukul 10.00. Berapa durasinya di rumah sakit penerima?','["48 jam.","74 jam 30 menit.","72 jam.","96 jam.","Tidak bisa dihitung karena intubasi dilakukan di rumah sakit lain."]','2','Selisih 8 November pukul 10.00 hingga 11 November pukul 10.00 adalah 72 jam. Waktu di rumah sakit pengirim tidak ditambahkan pada durasi episode penerima.'),
('2026-11-24.1','M4-02-0','M4-02','4','Alteplase intravena sudah diberikan. Apa kode tindakan pemberian trombolitik tersebut?','["99.20","99.29","99.19","99.10","99.21"]','3','99.10 untuk injeksi atau infus agen trombolitik.'),
('2026-11-24.1','M4-02-1','M4-02','4','Dokumen mana yang membuktikan alteplase sudah diberikan pada perawatan ini?','["Instruksi awal dokter tanpa catatan pelaksanaan.","Resep obat tanpa konfirmasi pemberian.","Catatan pemberian obat pada episode perawatan sebelumnya.","Daftar obat yang tersedia di farmasi.","Lembar pemberian obat atau catatan pelaksanaan yang membuktikan pemberian pada episode ini."]','4','Gunakan catatan pelaksanaan atau lembar pemberian obat yang menunjukkan tindakan sudah dikerjakan.'),
('2026-11-24.1','M4-02-2','M4-02','4','Jika berkas hanya memuat instruksi trombolisis tanpa bukti pemberian obat, apa yang harus dilakukan koder?','["Jangan tetapkan sebagai tindakan terlaksana sebelum ada bukti pemberian.","Tetapkan kode segera berdasarkan instruksi dokter.","Tetapkan kode jika obat sudah dipesan dari farmasi.","Tetapkan kode berdasarkan jadwal pemberian yang direncanakan.","Tetapkan kode jika nama obat muncul pada daftar resep."]','0','Tunda pengodean sampai tersedia bukti bahwa pemberian telah dilakukan.'),
('2026-11-24.1','M4-02-3','M4-02','4','Jika diagnosis akhir tidak tercantum, apakah koder boleh menetapkan penyakit hanya dari catatan pemberian trombolitik?','["Tidak. Diagnosis perlu didasarkan pada penetapan dokter, bukan disimpulkan dari tindakan saja.","Ya. Pemberian trombolitik cukup untuk menetapkan diagnosis stroke tertentu.","Ya. Rute infus menentukan diagnosis penyakitnya.","Ya. Dosis trombolitik dapat digunakan menggantikan diagnosis akhir dokter.","Ya. Nama kelompok obat sudah cukup untuk menetapkan kode diagnosis spesifik."]','0','Tidak. Diagnosis spesifik mengikuti diagnosis yang ditetapkan dokter, sementara catatan pemberian mendukung kode tindakan.'),
('2026-11-24.1','M4-03-0','M4-03','4','Pasien menjalani kontrol pascavitrektomi dan tidak dilakukan perawatan luka. Apa kode diagnosis utama kunjungan ini menurut ketentuan ICS?','["Z48.8","Z01.0","Z09.0","Z48.0","Z09.9"]','0','Z48.8 digunakan untuk kontrol pascaoperasi mata pada kasus ini.'),
('2026-11-24.1','M4-03-1','M4-03','4','Apa kode diagnosis sekunder untuk hipertensi esensial pada pasien ini?','["I95.9","I15.9","R03.0","I11.9","I10"]','4','I10 untuk hipertensi esensial.'),
('2026-11-24.1','M4-03-2','M4-03','4','Catatan tindakan hanya menyebut funduskopi. Pertanyaan klarifikasi mana yang tepat untuk mengetahui alat dan teknik pemeriksaannya?','["Mohon tuliskan bahwa pemeriksaan dilakukan dengan kamera fundus.","Mohon tuliskan bahwa pemeriksaan dilakukan dengan oftalmoskop.","Mohon gunakan kode foto fundus tanpa menambahkan rincian pemeriksaan.","Mohon jelaskan alat dan teknik pemeriksaan fundus yang digunakan pada kunjungan ini.","Mohon tentukan teknik pemeriksaan dari riwayat vitrektomi saja."]','3','Minta dokter menjelaskan alat dan teknik yang digunakan. Jangan langsung meminta dokter menyebut kamera fundus atau oftalmoskop, karena tekniknya belum diketahui dari catatan.'),
('2026-11-24.1','M4-03-3','M4-03','4','Pasangan kode mana yang tepat untuk foto fundus dan oftalmoskopi?','["Foto fundus 95.12 · oftalmoskopi 16.21","Foto fundus 95.11 · oftalmoskopi 95.12","Foto fundus 95.11 · oftalmoskopi 16.21","Foto fundus 16.21 · oftalmoskopi 95.11","Foto fundus 95.12 · oftalmoskopi 95.11"]','2','Foto fundus dikode 95.11. Oftalmoskopi dikode 16.21.'),
('2026-11-24.1','M4-04-0','M4-04','4','Pada pasien A, lesi telinga luar diangkat untuk terapi. Apa kode tindakannya?','["18.31","18.21","18.39","18.12","18.29"]','4','18.29 untuk eksisi lesi telinga luar pada laporan A.'),
('2026-11-24.1','M4-04-1','M4-04','4','Pada pasien B, sebagian jaringan telinga luar diambil untuk biopsi. Apa kode tindakannya?','["18.29","18.31","19.0","18.12","18.21"]','3','18.12 untuk biopsi telinga luar pada laporan B.'),
('2026-11-24.1','M4-04-2','M4-04','4','Jaringan biopsi pasien B sudah diperiksa secara histopatologi. Kelompok kode mana yang perlu ditelusuri untuk pemeriksaan tersebut?','["91.81","90.89","91.86-","91.85","91.82"]','2','Periksa kelompok 91.86- untuk pemeriksaan patologi anatomi sesuai petunjuk ICS. Tanda hubung berarti kode perlu dilengkapi sesuai rincian pemeriksaan; 91.86- bukan kode akhir untuk langsung dimasukkan.'),
('2026-11-24.1','M4-04-3','M4-04','4','Apa perbedaan tujuan pengambilan jaringan pada pasien A dan B?','["Laporan A: biopsi; laporan B: pengangkatan untuk terapi.","Keduanya biopsi karena lokasi tindakannya sama.","Laporan A: pengangkatan untuk terapi; laporan B: pengambilan sampel untuk biopsi.","Keduanya pengangkatan terapeutik karena sama-sama mengambil jaringan.","Laporan A: pemeriksaan tanpa pengambilan jaringan; laporan B: pengangkatan seluruh lesi."]','2','Pada laporan A, lesi diangkat untuk terapi. Pada laporan B, jaringan diambil untuk diperiksa sebagai biopsi.'),
('2026-11-24.1','M4-05-0','M4-05','4','Selain kode dasar TB, informasi resistansi apa yang perlu dilengkapi menurut ICS?','["Gejala pernapasan dan riwayat penyakit.","Pemeriksaan mikrobiologi dan tindakan radiologi.","Kategori resistansi TB (TB Episode of Care) dan jenis obat terkait resistansi (Drug Types).","Penyebab luar dan cedera.","Pemeriksaan radiologi dan administrasi kunjungan."]','2','ICS meminta penelusuran dua kelompok tambahan: TB Episode of Care untuk kategori resistansi TB, dan Drug Types untuk jenis obat terkait resistansi. Kategori resistansi dan obat yang terlibat harus diperjelas sebelum kode spesifik dipilih.'),
('2026-11-24.1','M4-05-1','M4-05','4','Data mana yang menjadi dasar pemilihan kode dasar TB pada pasien ini?','["Riwayat batuk saja.","Foto toraks saja tanpa diagnosis dokter.","Nama layanan TB tanpa lokasi penyakit.","TB paru yang ditetapkan dokter dan dikonfirmasi TCM dahak.","Berat badan turun tanpa pemeriksaan lain."]','3','Lokasi paru ditetapkan dokter dan Mycobacterium tuberculosis terdeteksi pada dahak. Kode dasar TB harus sesuai lokasi dan dasar konfirmasi, kemudian dilengkapi informasi resistansi sesuai ICS.'),
('2026-11-24.1','M4-05-2','M4-05','4','Obat apa yang sudah terbukti resistan berdasarkan hasil pemeriksaan?','["Isoniazid.","Semua obat TB lini pertama.","Fluorokuinolon.","Rifampisin.","Bedaquiline."]','3','TCM menyatakan resistansi rifampisin terdeteksi. Hasil untuk obat lain belum tersedia; resistansi terhadap obat-obat tersebut tidak boleh diasumsikan.'),
('2026-11-24.1','M4-05-3','M4-05','4','Apakah resistansi rifampisin saja sudah cukup untuk menetapkan MDR-TB?','["Ya, semua RR-TB pasti resistan terhadap isoniazid.","Belum; resistansi isoniazid perlu diketahui dan kategori akhir mengikuti penetapan dokter.","Ya, penurunan berat badan membuktikan resistansi ganda.","Ya, adanya kavitas membuktikan MDR-TB.","Tidak perlu menilai isoniazid karena semua obat dianggap resistan."]','1','MDR-TB memerlukan resistansi setidaknya terhadap isoniazid dan rifampisin. Kasus ini telah membuktikan RR-TB, sementara hasil isoniazid belum tersedia. Jangan mengubah bukti satu obat menjadi bukti beberapa obat.'),
('2026-11-24.1','M4-06-0','M4-06','4','Apa kode untuk angioplasti koroner perkutan yang sudah dilakukan?','["36.06","00.63","36.07","00.61","00.66"]','4','00.66 untuk tindakan PTCA.'),
('2026-11-24.1','M4-06-1','M4-06','4','PTCA dilakukan pada satu pembuluh koroner. Apa kode tambahan untuk jumlah pembuluh tersebut?','["00.42","00.41","00.40","00.43","00.45"]','2','00.40 menunjukkan tindakan pada satu pembuluh.'),
('2026-11-24.1','M4-06-2','M4-06','4','Satu stent dipasang pada tindakan ini. Apa kode tambahan untuk jumlah stent?','["00.47","00.45","00.48","00.46","00.40"]','1','00.45 menunjukkan jumlah stent yang dipasang, yaitu satu.'),
('2026-11-24.1','M4-06-3','M4-06','4','Jenis stent belum tercantum. Dokumen atau klarifikasi apa yang dibutuhkan sebelum menentukan kode jenis stent?','["Pilih drug-eluting stent karena hanya satu stent yang dipasang.","Pilih non-drug-eluting stent jika jenisnya belum tertulis.","Tentukan jenis stent dari jumlah pembuluh yang ditangani.","Salin jenis stent dari laporan tindakan pasien lain.","Periksa catatan implan atau minta operator menjelaskan jenis stent yang dipasang."]','4','Periksa kartu atau catatan implan, atau minta operator menjelaskan jenis stent yang dipasang pada episode ini.'),
('2026-11-24.1','M4-07-0','M4-07','4','Pasien A mengalami apendisitis akut dengan perforasi dan peritonitis umum. Apa kode diagnosisnya?','["K35.3","K35.8","K36","K37","K35.2"]','4','K35.2 untuk apendisitis akut dengan peritonitis umum.'),
('2026-11-24.1','M4-07-1','M4-07','4','Pasien B mengalami apendisitis akut dengan peritonitis lokal. Apa kode diagnosisnya?','["K35.3","K35.8","K37","K36","K35.2"]','0','K35.3 untuk apendisitis akut dengan peritonitis lokal.'),
('2026-11-24.1','M4-07-2','M4-07','4','Istilah mana yang membedakan luas peritonitis pada pasien A dari pasien B?','["Apendisitis akut.","Perforasi tanpa keterangan luas peritonitis.","Peritonitis umum.","Tindakan operasi.","Lokasi apendiks."]','2','Frasa “peritonitis umum” menunjukkan luas peritonitis pada episode A.'),
('2026-11-24.1','M4-07-3','M4-07','4','Apakah peritonitis perlu dikode terpisah jika sudah tercakup dalam kode apendisitis dengan peritonitis umum?','["Ya. Semua peritonitis selalu memerlukan kode terpisah.","Ya. Kode apendisitis hanya menunjukkan lokasi organ.","Ya. Perforasi selalu mengharuskan satu kode peritonitis tambahan.","Tidak. Peritonitis sudah tercakup dalam kode kombinasi yang dipilih.","Tidak. Peritonitis tidak disebut dalam resume A."]','3','Peritonitis umum sudah tercakup dalam kode kombinasi apendisitis akut pada episode A.'),
('2026-11-24.1','M4-08-0','M4-08','4','Batu duktus koledokus berhasil dikeluarkan secara endoskopik melalui ERCP. Apa kode tindakannya?','["51.88","51.87","51.10","51.11","51.85"]','0','51.88 untuk pengangkatan batu dari saluran empedu secara endoskopik pada kasus ini.'),
('2026-11-24.1','M4-08-1','M4-08','4','Apakah kode ERCP diagnostik 51.10 perlu ditambahkan pada tindakan pengeluaran batu yang sama?','["Ya. Setiap ERCP terapeutik selalu memerlukan kode ERCP diagnostik tambahan.","Tidak. Pada kasus ini, kode pengambilan batu sudah mencakup pelaksanaan melalui ERCP.","Ya. Judul “ERCP” harus diberi kode terpisah dari uraian tindakan pada sesi yang sama.","Ya. Pengambilan batu dan ERCP pada laporan ini dianggap sebagai dua sesi berbeda.","Tidak. ERCP hanya direncanakan dan belum dilakukan."]','1','Untuk contoh ini, gunakan kode tindakan yang spesifik. Kode ERCP diagnostik 51.10 tidak ditambahkan pada sesi yang sama.'),
('2026-11-24.1','M4-08-2','M4-08','4','Catatan mana yang membuktikan pengeluaran batu sudah dilakukan?','["Judul laporan menyebut ERCP.","Diagnosis mencantumkan batu saluran empedu.","Instruksi mencantumkan rencana pengambilan batu.","Jadwal tindakan mencantumkan nama operator.","Uraian operator menyatakan batu berhasil dikeluarkan dari saluran empedu secara endoskopik."]','4','Uraian operator menyatakan bahwa batu telah dikeluarkan dari saluran empedu melalui endoskop.'),
('2026-11-24.1','M4-08-3','M4-08','4','Jika laporan hanya bertuliskan ERCP, informasi apa yang harus diperiksa sebelum mengode pengeluaran batu?','["Lama rawat dan kelas perawatan.","Riwayat pengambilan batu pada episode sebelumnya.","Identitas operator dan nomor ruangan saja.","Biaya tindakan dan jadwal pemeriksaan.","Uraian tindakan yang terlaksana, termasuk lokasi batu dan bukti bahwa batu dikeluarkan."]','4','Periksa uraian prosedur untuk memastikan bahwa pengambilan batu terlaksana dan bahwa batunya berasal dari saluran empedu.'),
('2026-11-24.1','M4-09-0','M4-09','4','Apa kode tindakan artroskopi lutut?','["80.27","80.25","80.26","80.21","81.45"]','2','80.26 untuk artroskopi lutut.'),
('2026-11-24.1','M4-09-1','M4-09','4','Operator melakukan reparasi ligamen krusiat kategori other repair. Apa kode untuk reparasi tersebut?','["80.26","81.47","81.46","81.45","81.44"]','3','Gunakan 81.45 untuk other repair of the cruciate ligaments, yaitu kategori reparasi lain ligamen krusiat sebagaimana dicatat pada laporan.'),
('2026-11-24.1','M4-09-2','M4-09','4','Apakah reparasi ligamen krusiat yang dilakukan bersama artroskopi termasuk prosedur kompleks menurut daftar ICS?','["Tidak. Artroskopi dengan reparasi ligamen tetap selalu termasuk prosedur diagnostik.","Tidak. Tindakan pada sendi yang sama tidak boleh dinilai sebagai prosedur kompleks.","Ya. Reparasi tersebut termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.","Ya. Semua artroskopi termasuk kompleks, tanpa melihat tindakan tambahannya.","Tidak. Reparasi hanya dianggap kompleks jika dilakukan pada hari yang berbeda."]','2','Ya. Reparasi yang didokumentasikan termasuk dalam daftar prosedur kompleks untuk artroskopi pada ICS.'),
('2026-11-24.1','M4-09-3','M4-09','4','Bagian berkas mana yang membuktikan reparasi ligamen sudah dilakukan meskipun judul tindakan hanya menyebut artroskopi?','["Judul laporan yang hanya menulis artroskopi lutut.","Diagnosis yang menyebut keluhan lutut.","Jadwal operasi tanpa catatan pelaksanaan.","Uraian operasi yang menyebut ligamen krusiat dan reparasi yang telah dilakukan.","Formulir persetujuan tindakan tanpa laporan operasi."]','3','Uraian operasi menyebut ligamen yang ditangani dan menyatakan bahwa reparasi dilakukan.'),
('2026-11-24.1','M4-10-0','M4-10','4','Pada pasien A, jaringan kulit dan subkutis yang mati dieksisi saat debridemen. Apa kode tindakannya?','["86.59","86.22","86.28","86.04","86.09"]','1','86.22 untuk debridemen eksisional pada kasus ini.'),
('2026-11-24.1','M4-10-1','M4-10','4','Pada pasien B, debridemen dilakukan tanpa eksisi jaringan. Apa kode tindakannya?','["86.28","86.59","86.09","86.22","86.04"]','0','86.28 untuk debridemen noneksisional.'),
('2026-11-24.1','M4-10-2','M4-10','4','Catatan mana yang menunjukkan debridemen pasien A dilakukan secara eksisional?','["Operator mencatat eksisi jaringan luka.","Dokter hanya mencatat lokasi luka.","Jadwal menyebut rencana perawatan luka.","Catatan menyebut pembersihan tanpa eksisi.","Kolom prosedur hanya menulis debridemen tanpa teknik."]','0','Frasa “mengeksisi jaringan luka” menunjukkan teknik eksisional.'),
('2026-11-24.1','M4-10-3','M4-10','4','Laporan pasien C hanya menyebut debridemen. Pertanyaan klarifikasi mana yang tepat sebelum menentukan kode?','["Mohon nyatakan debridemen eksisional agar kode dapat dipilih.","Mohon nyatakan kedalaman tertentu tanpa memeriksa laporan operasi.","Mohon ganti judul tindakan menjadi debridemen eksisional.","Mohon tentukan kode dari judul tindakan tanpa rincian teknik.","Mohon jelaskan teknik debridemen dan jaringan yang ditangani pada tindakan ini."]','4','Tanyakan teknik debridemen serta jaringan yang ditangani tanpa menyarankan teknik tertentu.'),
('2026-11-24.1','M4-11-0','M4-11','4','Pada pasien A, dokter menetapkan diabetes melitus tipe 2 dengan ulkus diabetik. Apa kode diagnosisnya menurut ICS?','["E10.5","E11.9","E11.6","E11.4","E11.5"]','4','E11.5 adalah kode kombinasi yang digunakan untuk diagnosis menurut ICS.'),
('2026-11-24.1','M4-11-1','M4-11','4','Istilah mana pada diagnosis pasien A yang menunjukkan hubungan ulkus dengan diabetes?','["“Diabetes melitus tipe 2” tanpa keterangan komplikasi.","“Ulkus” tanpa keterangan hubungan dengan diabetes.","“Ulkus diabetik”.","Dua diagnosis yang dicatat pada baris terpisah tanpa penjelasan.","Riwayat diabetes saja."]','2','“Ulkus diabetik” menyatakan bahwa dokter mengaitkan ulkus dengan diabetes.'),
('2026-11-24.1','M4-11-2','M4-11','4','Menurut ketentuan ICS yang digunakan pada kasus ini, apakah ulkus perlu dikode terpisah setelah diabetes dengan ulkus dikode?','["Ya. Semua ulkus harus selalu diberi kode terpisah.","Ya. Diabetes harus dikode tanpa komplikasi lalu ditambah kode ulkus.","Tidak. Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi.","Ya. Hubungan diabetes dan ulkus belum dinyatakan pada resume utama.","Tidak. Ulkus hanya merupakan rencana diagnosis."]','2','Pada contoh ini, ulkus sudah tercakup dalam kode kombinasi sehingga tidak dicatat lagi sebagai diagnosis sekunder.'),
('2026-11-24.1','M4-11-3','M4-11','4','Pada pasien B, hubungan diabetes dengan ulkus belum dijelaskan. Apa pertanyaan klarifikasi yang tepat?','["Mohon pastikan bahwa ulkus merupakan komplikasi diabetes.","Mohon jelaskan hubungan klinis antara diabetes dan ulkus, bila ada.","Mohon ganti diagnosis ulkus menjadi ulkus diabetik.","Mohon nyatakan bahwa ulkus tidak berkaitan dengan diabetes.","Mohon pilih kode kombinasi tanpa menjelaskan hubungan klinis."]','1','Tanyakan apakah ulkus memiliki hubungan klinis dengan diabetes. Pertanyaan ini meminta penjelasan, tanpa mengarahkan dokter untuk menyatakan bahwa ulkus pasti merupakan komplikasi diabetes.'),
('2026-11-24.1','M6-01-0','M6-01','6','DPJP belum menulis stadium AKI pasien A. Apa pertanyaan klarifikasi yang tepat?','["Mohon tetapkan stadium 3 karena ada pemasangan kateter pada berkas lain.","Mohon jelaskan stadium AKI pada episode ini, bila dapat ditentukan secara klinis.","Mohon tetapkan stadium tertinggi untuk mengantisipasi perburukan.","Mohon tetapkan stadium 1 karena belum ada rincian pemeriksaan.","Mohon tentukan stadium hanya dari nama tindakan pada berkas lain."]','1','Minta DPJP menjelaskan stadium AKI bila dapat ditentukan, tanpa mengusulkan salah satu stadium.'),
('2026-11-24.1','M6-01-1','M6-01','6','Kreatinin pasien A meningkat, tetapi stadium AKI belum ditulis. Apa langkah yang tepat sebelum memilih kode AKI dengan stadium tertentu?','["Langsung menetapkan stadium tertinggi.","Mengambil stadium dari pasien B.","Meminta DPJP mendokumentasikan atau mengonfirmasi stadium berdasarkan data episode A.","Menganggap semua AKI tanpa stadium sebagai stadium 1.","Mengode berdasarkan pemasangan kateter pada episode B."]','2','Data serial membantu klarifikasi, tetapi koder tidak menetapkan stadium sendiri. Minta penjelasan DPJP secara netral dan gunakan hanya data pasien A. Dokumen pasien B tidak berhubungan dengan episode ini.'),
('2026-11-24.1','M6-01-2','M6-01','6','Pasien B sudah menjalani pemasangan kateter dialisis bertunnel. Apa kode tindakan spesifiknya menurut ICS?','["38.950","39.27","39.95","38.95","54.932"]','0','38.950 sesuai untuk pemasangan tunneled dialysis catheter menurut ICS.'),
('2026-11-24.1','M6-01-3','M6-01','6','Kateter dialisis pasien B sudah dipasang, tetapi dialisis belum dilakukan. Apakah kode pelaksanaan dialisis boleh langsung ditambahkan?','["Tidak. Pelaksanaan dialisis memerlukan bukti tersendiri, terpisah dari pemasangan akses.","Ya. Pemasangan kateter selalu berarti sesi dialisis sudah selesai.","Ya. Nama kateter yang mengandung kata dialisis sudah cukup sebagai bukti.","Ya. Laporan pemasangan akses menggantikan catatan sesi dialisis.","Ya. Kode pemasangan akses dan kode pelaksanaan dialisis mempunyai arti yang sama."]','0','Pemasangan kateter menyediakan akses dialisis. Hal itu belum membuktikan sesi dialisis sudah dilakukan. Kode pelaksanaan dialisis memerlukan catatan pelaksanaan tersendiri.'),
('2026-11-24.1','M6-02-0','M6-02','6','Ibu mengalami ketuban pecah dini dan persalinan dimulai enam jam kemudian. Apa kode diagnosis utama pada berkas ibu?','["O42.0","Z37.0","O80.0","O42.9","O42.1"]','0','O42.0 untuk ketuban pecah dini dengan awal persalinan dalam 24 jam.'),
('2026-11-24.1','M6-02-1','M6-02','6','Bagaimana mengode dan menempatkan persalinan spontan presentasi kepala pada berkas ibu ini?','["O81.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis utama","O42.0 sebagai diagnosis sekunder","O80.0 sebagai diagnosis sekunder","O82.0 sebagai diagnosis sekunder"]','3','O80.0 dicatat sebagai diagnosis sekunder untuk cara persalinan spontan presentasi kepala.'),
('2026-11-24.1','M6-02-2','M6-02','6','Bagaimana mengode dan menempatkan hasil kelahiran satu bayi hidup pada berkas ibu?','["Z38.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder","Z37.1 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis sekunder","Z37.0 sebagai diagnosis utama"]','3','Z37.0 dicatat sebagai diagnosis sekunder untuk hasil satu bayi lahir hidup.'),
('2026-11-24.1','M6-02-3','M6-02','6','Apa pasangan kode tindakan untuk persalinan spontan dan episiotomi yang telah dilakukan?','["72.1, 73.6","73.59, 72.1","73.59, 73.6","73.4, 73.6","73.59, 75.69"]','2','Gunakan 73.59 dan 73.6. Kode 73.6 adalah kode episiotomi.'),
('2026-11-24.1','M6-03-0','M6-03','6','Apa kode diagnosis utama untuk hipoglikemia neonatal yang ditetapkan dokter?','["P70.0","P70.4","P70.1","P70.8","P70.9"]','1','P70.4 untuk hipoglikemia neonatal pada kasus ini.'),
('2026-11-24.1','M6-03-1','M6-03','6','Apa kode dan penempatan diagnosis untuk status bayi tunggal yang lahir di rumah sakit?','["Z37.0 sebagai diagnosis sekunder","Z38.1 sebagai diagnosis sekunder","Z38.0 sebagai diagnosis utama","Z37.0 sebagai diagnosis utama","Z38.0 sebagai diagnosis sekunder"]','4','Z38.0 dicatat sebagai diagnosis sekunder untuk bayi tunggal yang lahir di rumah sakit.'),
('2026-11-24.1','M6-03-2','M6-03','6','Informasi mana pada catatan kelahiran yang mendasari penggunaan Z38.0?','["Bayi tunggal dan berat lahir 3.000 gram.","Bayi cukup bulan dan berat lahir 3.000 gram.","Hipoglikemia dan hasil pemeriksaan penunjang.","Bayi tunggal dan lahir di rumah sakit.","Bayi cukup bulan dan diagnosis hipoglikemia."]','3','Bayi lahir tunggal dan tempat lahirnya di rumah sakit.'),
('2026-11-24.1','M6-03-3','M6-03','6','Apakah Z37.0 digunakan untuk mencatat status kelahiran pada berkas bayi ini?','["Ya. Z37.0 digunakan untuk semua bayi yang lahir di rumah sakit.","Ya. Z37.0 menjadi diagnosis utama untuk hipoglikemia neonatal.","Tidak. Z37.0 digunakan untuk hasil persalinan pada berkas ibu; status kelahiran bayi memakai kategori Z38.","Ya. Z37.0 menggantikan kode status kelahiran bayi.","Tidak. Status kelahiran bayi tidak perlu dicatat meskipun tersedia pada sumber."]','2','Z37.0 mencatat hasil persalinan pada episode ibu. Pada episode bayi, status kelahiran dicatat dengan kode yang sesuai dari kategori Z38.'),
('2026-11-24.1','M6-04-0','M6-04','6','Pasien masuk karena pielonefritis akut, kemudian mengalami sepsis pada hari kedua. Apa kode diagnosis utama berdasarkan kronologi perawatan ini?','["N39.0","A41.5","N11.9","N10","N12"]','3','N10 untuk pielonefritis akut sebagai diagnosis utama pada episode ini.'),
('2026-11-24.1','M6-04-1','M6-04','6','Apa kode diagnosis sekunder untuk sepsis akibat E. coli menurut klasifikasi yang digunakan?','["A41.0","A41.8","A40.9","A41.5","A41.9"]','3','A41.5 untuk sepsis akibat organisme Gram-negatif lain, sebagaimana digunakan menurut ICS.'),
('2026-11-24.1','M6-04-2','M6-04','6','Apa kode tambahan untuk E. coli sebagai penyebab pielonefritis?','["B96.8","B96.5","B96.2","B96.1","B95.6"]','2','B96.2 mencatat E. coli sebagai organisme penyebab.'),
('2026-11-24.1','M6-04-3','M6-04','6','Catatan mana yang memastikan diagnosis sepsis sudah ditegakkan dokter, bukan hanya menunjukkan kultur positif?','["Kultur darah positif tanpa diagnosis sepsis dari dokter.","Demam dan menggigil saja.","DPJP secara jelas menuliskan diagnosis “sepsis akibat E. coli”.","Tekanan darah 120/70 mmHg saja.","Kultur urin positif tanpa penetapan diagnosis sepsis."]','2','DPJP secara eksplisit menetapkan “sepsis akibat E. coli”. Kultur positif membantu mengidentifikasi organisme dan harus dibaca bersama diagnosis dokter.'),
('2026-11-24.1','M6-05-0','M6-05','6','DPJP menetapkan cedera multipel intratorakal sebagai kondisi utama dan fraktur terbuka humerus proksimal sebagai kondisi lain. Apa pasangan kode diagnosisnya?','["Diagnosis utama S42.21 · diagnosis sekunder S27.7","Diagnosis utama S27.7 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.31","Diagnosis utama S27.9 · diagnosis sekunder S42.21","Diagnosis utama S27.7 · diagnosis sekunder S42.20"]','1','S27.7 menjadi diagnosis utama untuk cedera multipel organ intratorakal. S42.21 menjadi diagnosis sekunder untuk fraktur terbuka humerus proksimal pada kasus ini.'),
('2026-11-24.1','M6-05-1','M6-05','6','Pasien mengemudikan mobil yang menabrak pohon di jalan umum. Apa kode penyebab luarnya?','["V49.9","V47.59","V89.2","V47.69","V47.09"]','1','V47.59 adalah kode penyebab luar yang digunakan menurut ICS.'),
('2026-11-24.1','M6-05-2','M6-05','6','Apa pasangan kode untuk pemasangan WSD dan ORIF humerus kiri yang sudah dilakukan?','["WSD 34.04 · ORIF 79.31","WSD 34.04 · ORIF 79.19","WSD 79.39 · ORIF 34.04","WSD 34.04 · ORIF 79.39","WSD 34.91 · ORIF 79.39"]','0','Pemasangan drain interkostal/WSD dikode 34.04. Reduksi terbuka fraktur humerus dengan fiksasi internal dikode 79.31. Kode 79.39 digunakan untuk tulang lain yang ditentukan, bukan humerus. Pilihan mengikuti lokasi tulang dan tindakan pada laporan operasi.'),
('2026-11-24.1','M6-05-3','M6-05','6','Cedera dada dan humerus termasuk dalam dua kelompok lokasi tubuh apa saat menilai kriteria MDC 31?','["Dada dan ekstremitas atas","Abdomen dan ekstremitas atas","Pelvis dan ekstremitas atas","Kepala dan dada","Dada dan ekstremitas bawah"]','0','Lokasi cedera adalah dada dan ekstremitas atas atau anggota gerak atas. Humerus termasuk ekstremitas atas. Informasi lokasi ini digunakan untuk menelaah kriteria trauma; penetapan MDC tetap mengikuti kriteria grouper.'),
('2026-11-24.1','M6-06-0','M6-06','6','Pasien datang untuk menjalani sesi terapi fisik. Apa kode diagnosis utama kunjungan ini?','["Z50.8","Z50.0","Z50.1","Z51.8","M54.5"]','2','Z50.1 untuk kunjungan terapi fisik pada kasus ini.'),
('2026-11-24.1','M6-06-1','M6-06','6','Apa kode diagnosis sekunder untuk nyeri punggung bawah menurut klasifikasi yang digunakan?','["Z50.1","M54.5","M54.4","M54.6","M54.9"]','1','M54.5 adalah kode nyeri punggung bawah yang digunakan pada kasus ini.'),
('2026-11-24.1','M6-06-2','M6-06','6','Apa kode untuk tindakan peregangan yang telah diberikan?','["93.27","93.11","93.28","93.35","93.12"]','0','93.27 untuk peregangan pada kasus ini.'),
('2026-11-24.1','M6-06-3','M6-06','6','Apa kode untuk terapi inframerah yang telah diberikan?','["93.32","93.27","93.35","93.34","93.39"]','2','93.35 untuk terapi inframerah pada kasus ini.'),
('2026-11-24.1','M6-07-0','M6-07','6','Whirlpool sudah diberikan, tetapi hasil grouping menyebut rehabilitasi tanpa prosedur. Apa kesalahan pada isian aplikasi?','["Kode prosedur whirlpool belum diisi meskipun terapi sudah dilaksanakan.","Kode diagnosis utama belum diisi.","Kode diagnosis sekunder belum diisi.","Terapi whirlpool belum dilaksanakan karena hasil grouper menyebut tanpa prosedur.","Kode hasil grouper sudah menjadi pengganti kode prosedur whirlpool."]','0','Catatan terapi menyatakan whirlpool sudah diberikan, tetapi kolom tindakan belum diisi. Petugas perlu memasukkan kode tindakan yang sesuai, bukan menganggap terapi tidak dilakukan hanya karena uraian hasil grouping.'),
('2026-11-24.1','M6-07-1','M6-07','6','Apa kode tindakan whirlpool yang perlu dimasukkan?','["93.35","93.31","93.33","93.39","93.32"]','4','93.32 untuk terapi whirlpool.'),
('2026-11-24.1','M6-07-2','M6-07','6','Setelah kode whirlpool ditambahkan, apa langkah berikutnya pada aplikasi grouper?','["Gunakan hasil lama dan cukup ubah uraiannya.","Validasi kembali isian yang diperbarui, lalu jalankan pengelompokan ulang.","Catat kode prosedur tanpa menjalankan pengelompokan ulang.","Jalankan pengelompokan ulang sebelum memasukkan kode prosedur.","Ubah diagnosis utama tanpa memeriksa catatan terapi."]','1','Periksa dan validasi kembali isian yang sudah ditambahkan, lalu jalankan grouping ulang. Hasil sebelum perbaikan tidak digunakan sebagai hasil akhir setelah isian berubah.'),
('2026-11-24.1','M6-07-3','M6-07','6','Apa yang perlu diperiksa dan dicatat setelah grouping ulang?','["Pertahankan kode dan uraian hasil lama tanpa memeriksa hasil baru.","Periksa apakah keluaran lama sudah berubah, lalu catat kode dan uraian yang benar-benar muncul setelah pengelompokan ulang.","Catat kode hasil yang diperkirakan muncul meskipun aplikasi belum dijalankan ulang.","Catat kode prosedur saja tanpa meninjau hasil pengelompokan.","Nyatakan koreksi berhasil hanya karena kolom prosedur sudah terisi."]','1','Baca hasil grouping yang baru, periksa apakah masalah “rehabilitasi tanpa prosedur” sudah teratasi, lalu catat kode dan uraian yang benar-benar tampil. Jangan menebak kode hasil setelah perbaikan.'),
('2026-11-24.1','M6-08-0','M6-08','6','Pasien A sudah menjalani CT kepala. Apa kode pemeriksaannya?','["87.04","88.38","87.02","87.03","88.91"]','3','87.03 untuk CT kepala.'),
('2026-11-24.1','M6-08-1','M6-08','6','Pasien B sudah menjalani MRI otak dan batang otak. Apa kode pemeriksaannya?','["88.97","87.03","88.91","88.93","88.92"]','2','88.91 untuk MRI otak dan batang otak menurut ICS.'),
('2026-11-24.1','M6-08-2','M6-08','6','Apa kode tambahan untuk pemberian kontras pada CT kepala pasien A menurut ICS?','["99.10","99.290","99.21","99.20","99.250"]','1','99.290 menunjukkan pemberian bahan kontras pada pemeriksaan CT yang tercatat.'),
('2026-11-24.1','M6-08-3','M6-08','6','Apa kode tambahan untuk pemberian kontras pada MRI kepala pasien B menurut ICS?','["99.290","99.10","99.21","99.250","99.20"]','0','99.290 juga digunakan untuk pemberian bahan kontras pada pemeriksaan MRI yang tercatat.')
on conflict(revision,item_id) do nothing;
commit;
