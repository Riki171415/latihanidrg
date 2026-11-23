-- Run as project owner. No password or privileged API key belongs in these tables.
begin;
create schema if not exists idrg_private;
revoke all on schema idrg_private from public, anon, authenticated;

create table public.idrg_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  email text not null,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,30}$'),
  phone text not null check (phone ~ '^\+?[0-9 ()-]{8,25}$' and length(regexp_replace(phone,'[^0-9]','','g')) between 8 and 15),
  institution text not null check (length(trim(institution)) between 2 and 160),
  created_at timestamptz not null default now()
);
create table idrg_private.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role = 'admin')
);
create table idrg_private.admin_allowlist (email text primary key check (email=lower(email)));
create table idrg_private.bank_versions (
  revision text primary key,
  active boolean not null default false
);
create unique index one_active_idrg_bank on idrg_private.bank_versions (active) where active;
create table idrg_private.questions (
  revision text not null references idrg_private.bank_versions(revision),
  item_id text not null,
  case_id text not null,
  packet_id text not null check (packet_id in ('2-casemix','2-coding','4','6')),
  prompt text not null,
  options jsonb not null check (jsonb_array_length(options)=5),
  correct smallint not null check (correct between 0 and 4),
  feedback text not null,
  primary key (revision,item_id)
);
create table public.idrg_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  packet_id text not null check (packet_id in ('2-casemix','2-coding','4','6')),
  revision text not null references idrg_private.bank_versions(revision),
  answers jsonb not null default '{}'::jsonb,
  case_index integer not null default 0,
  question_index integer not null default 0,
  version integer not null default 0,
  correct_count integer,
  total_count integer not null,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,packet_id,revision),
  check (case_index>=0 and question_index between 0 and 3),
  check (correct_count is null or correct_count between 0 and total_count)
);
create index idrg_attempts_owner on public.idrg_attempts(user_id);
create index idrg_attempts_revision on public.idrg_attempts(revision);
create index idrg_attempts_latest on public.idrg_attempts(user_id,packet_id,created_at desc);
create index idrg_profiles_institution on public.idrg_profiles(institution);

create function idrg_private.idrg_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null
    and (exists(select 1 from idrg_private.staff_roles r where r.user_id=u.id and r.role='admin')
      or exists(select 1 from idrg_private.admin_allowlist a where a.email=lower(u.email))));
$$;
create function public.idrg_is_admin() returns boolean
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_is_admin();
$$;
revoke all on function public.idrg_is_admin() from public,anon;
grant execute on function public.idrg_is_admin() to authenticated;

create function idrg_private.create_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.idrg_profiles(user_id,email,full_name,username,phone,institution)
  values(new.id,new.email,trim(new.raw_user_meta_data->>'full_name'),
    lower(trim(new.raw_user_meta_data->>'username')),trim(new.raw_user_meta_data->>'phone'),
    trim(new.raw_user_meta_data->>'institution'));
  return new;
end;
$$;
create trigger idrg_profile_on_signup after insert on auth.users
for each row execute function idrg_private.create_profile();
create function idrg_private.sync_profile_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.idrg_profiles set email=new.email where user_id=new.id;
  return new;
end;
$$;
create trigger idrg_profile_email after update of email on auth.users
for each row execute function idrg_private.sync_profile_email();

alter table public.idrg_profiles enable row level security;
alter table public.idrg_attempts enable row level security;
alter table idrg_private.questions enable row level security;
alter table idrg_private.staff_roles enable row level security;
alter table idrg_private.admin_allowlist enable row level security;
alter table idrg_private.bank_versions enable row level security;
revoke all on public.idrg_profiles,public.idrg_attempts from public,anon,authenticated;
grant select on public.idrg_profiles,public.idrg_attempts to authenticated;
grant update(full_name,username,phone,institution) on public.idrg_profiles to authenticated;
create policy own_profile_read on public.idrg_profiles for select to authenticated
using(user_id=(select auth.uid()) or (select public.idrg_is_admin()));
create policy own_profile_update on public.idrg_profiles for update to authenticated
using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy own_attempt_read on public.idrg_attempts for select to authenticated
using(user_id=(select auth.uid()) or (select public.idrg_is_admin()));

create function idrg_private.idrg_complete_profile(p_full_name text,p_username text,p_phone text,p_institution text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare person public.idrg_profiles; address text;
begin
  if auth.uid() is null then raise exception 'Silakan masuk terlebih dahulu.' using errcode='42501'; end if;
  select email into address from auth.users where id=auth.uid();
  insert into public.idrg_profiles(user_id,email,full_name,username,phone,institution)
  values(auth.uid(),address,trim(p_full_name),lower(trim(p_username)),trim(p_phone),trim(p_institution))
  on conflict(user_id) do update set full_name=excluded.full_name,username=excluded.username,
    phone=excluded.phone,institution=excluded.institution returning * into person;
  return to_jsonb(person);
end;
$$;
create function public.idrg_complete_profile(p_full_name text,p_username text,p_phone text,p_institution text) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_complete_profile(p_full_name,p_username,p_phone,p_institution);
$$;
revoke all on function public.idrg_complete_profile(text,text,text,text) from public,anon;
grant execute on function public.idrg_complete_profile(text,text,text,text) to authenticated;

create function idrg_private.idrg_start_packet(p_packet_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); rev text; total integer; attempt public.idrg_attempts;
begin
  if uid is null then raise exception 'Silakan masuk terlebih dahulu.' using errcode='42501'; end if;
  select revision into rev from idrg_private.bank_versions where active;
  select count(*) into total from idrg_private.questions where revision=rev and packet_id=p_packet_id;
  if total=0 then raise exception 'Paket latihan belum tersedia.'; end if;
  insert into public.idrg_attempts(user_id,packet_id,revision,total_count)
    values(uid,p_packet_id,rev,total) on conflict(user_id,packet_id,revision) do nothing;
  select * into attempt from public.idrg_attempts where user_id=uid and packet_id=p_packet_id and revision=rev;
  return to_jsonb(attempt);
end;
$$;
create function public.idrg_start_packet(p_packet_id text) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_start_packet(p_packet_id);
$$;

create function idrg_private.idrg_save_attempt(p_id uuid,p_answers jsonb,p_case_index integer,p_question_index integer,p_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare attempt public.idrg_attempts; case_count integer;
begin
  select * into attempt from public.idrg_attempts where id=p_id and user_id=auth.uid() for update;
  if not found then raise exception 'Latihan tidak ditemukan.' using errcode='42501'; end if;
  if attempt.submitted_at is not null then raise exception 'Paket sudah dikirim. Jawaban tidak dapat diubah.'; end if;
  if p_version is null or attempt.version<>p_version then raise exception 'Data berubah pada perangkat lain. Muat ulang sebelum melanjutkan.' using errcode='40001'; end if;
  if p_answers is null or jsonb_typeof(p_answers)<>'object' or octet_length(p_answers::text)>20000 then
    raise exception 'Format jawaban tidak valid.';
  end if;
  if exists(select 1 from jsonb_each(p_answers) a left join idrg_private.questions q
    on q.item_id=a.key and q.packet_id=attempt.packet_id and q.revision=attempt.revision
    where q.item_id is null or jsonb_typeof(a.value)<>'string' or a.value::text not in ('"0"','"1"','"2"','"3"','"4"')) then
    raise exception 'Jawaban tidak sesuai dengan paket latihan.';
  end if;
  select count(distinct case_id) into case_count from idrg_private.questions where packet_id=attempt.packet_id and revision=attempt.revision;
  if p_case_index is null or p_case_index<0 or p_case_index>=case_count or p_question_index is null or p_question_index not between 0 and 3 then
    raise exception 'Posisi soal tidak valid.';
  end if;
  update public.idrg_attempts set answers=p_answers,case_index=p_case_index,question_index=p_question_index,
    version=version+1,updated_at=now() where id=p_id returning * into attempt;
  return to_jsonb(attempt);
end;
$$;
create function public.idrg_save_attempt(p_id uuid,p_answers jsonb,p_case_index integer,p_question_index integer,p_version integer) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_save_attempt(p_id,p_answers,p_case_index,p_question_index,p_version);
$$;

create function idrg_private.idrg_submit_attempt(p_id uuid,p_answers jsonb,p_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare attempt public.idrg_attempts; saved jsonb; right_count integer;
begin
  select * into attempt from public.idrg_attempts where id=p_id and user_id=auth.uid() for update;
  if not found then raise exception 'Latihan tidak ditemukan.' using errcode='42501'; end if;
  if attempt.submitted_at is not null then return to_jsonb(attempt); end if;
  saved:=public.idrg_save_attempt(p_id,p_answers,attempt.case_index,attempt.question_index,p_version);
  select count(*) into right_count from idrg_private.questions q where q.packet_id=attempt.packet_id
    and q.revision=attempt.revision and p_answers->>q.item_id=q.correct::text;
  update public.idrg_attempts set correct_count=right_count,submitted_at=now(),updated_at=now(),version=version+1
    where id=p_id returning * into attempt;
  return to_jsonb(attempt);
end;
$$;
create function public.idrg_submit_attempt(p_id uuid,p_answers jsonb,p_version integer) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_submit_attempt(p_id,p_answers,p_version);
$$;

create function idrg_private.idrg_review(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare attempt public.idrg_attempts; result jsonb;
begin
  select * into attempt from public.idrg_attempts where id=p_id
    and (user_id=auth.uid() or public.idrg_is_admin()) and submitted_at is not null;
  if not found then raise exception 'Pembahasan tersedia setelah paket dikirim.' using errcode='42501'; end if;
  select jsonb_agg(jsonb_build_object('item_id',q.item_id,'prompt',q.prompt,'options',q.options,
    'correct',q.correct,'feedback',q.feedback) order by q.item_id) into result
    from idrg_private.questions q where q.packet_id=attempt.packet_id and q.revision=attempt.revision;
  return result;
end;
$$;
create function public.idrg_review(p_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_review(p_id);
$$;

create function idrg_private.idrg_admin_dashboard(p_search text default '',p_institution text default '',p_page integer default 0,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if not public.idrg_is_admin() then raise exception 'Akses pengelola diperlukan.' using errcode='42501'; end if;
  with filtered as (
    select p.* from public.idrg_profiles p where
      (coalesce(p_institution,'')='' or p.institution=p_institution) and
      (coalesce(p_search,'')='' or position(lower(p_search) in lower(p.full_name||' '||p.email||' '||p.username))>0)
  ), latest as (
    select distinct on(a.user_id,a.packet_id) a.* from public.idrg_attempts a
    order by a.user_id,a.packet_id,a.created_at desc
  ), page_rows as (
    select f.*,coalesce((select jsonb_agg(to_jsonb(a) order by a.packet_id) from latest a where a.user_id=f.user_id),'[]'::jsonb) attempts
    from filtered f order by f.created_at desc,f.user_id
    limit greatest(1,least(p_page_size,100)) offset greatest(0,p_page)*greatest(1,least(p_page_size,100))
  ) select jsonb_build_object(
    'participants',(select count(*) from filtered),
    'submitted',(select count(*) from latest a join filtered f on f.user_id=a.user_id where a.submitted_at is not null),
    'average',(select round(100.0*sum(a.correct_count)/nullif(sum(a.total_count),0),1) from latest a join filtered f on f.user_id=a.user_id where a.submitted_at is not null),
    'rows',coalesce((select jsonb_agg(to_jsonb(p)) from page_rows p),'[]'::jsonb),
    'institutions',coalesce((select jsonb_agg(t.institution) from (select distinct institution from public.idrg_profiles order by institution) t),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;
create function public.idrg_admin_dashboard(p_search text default '',p_institution text default '',p_page integer default 0,p_page_size integer default 25) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select idrg_private.idrg_admin_dashboard(p_search,p_institution,p_page,p_page_size);
$$;

revoke all on function public.idrg_start_packet(text),public.idrg_save_attempt(uuid,jsonb,integer,integer,integer),
 public.idrg_submit_attempt(uuid,jsonb,integer),public.idrg_review(uuid),public.idrg_admin_dashboard(text,text,integer,integer)
from public,anon;
grant execute on function public.idrg_start_packet(text),public.idrg_save_attempt(uuid,jsonb,integer,integer,integer),
 public.idrg_submit_attempt(uuid,jsonb,integer),public.idrg_review(uuid),public.idrg_admin_dashboard(text,text,integer,integer)
to authenticated;
revoke all on all functions in schema idrg_private from public,anon,authenticated;
grant usage on schema idrg_private to authenticated;
grant execute on function idrg_private.idrg_is_admin(),idrg_private.idrg_complete_profile(text,text,text,text),
 idrg_private.idrg_start_packet(text),idrg_private.idrg_save_attempt(uuid,jsonb,integer,integer,integer),
 idrg_private.idrg_submit_attempt(uuid,jsonb,integer),idrg_private.idrg_review(uuid),
 idrg_private.idrg_admin_dashboard(text,text,integer,integer) to authenticated;
-- The platform RLS event trigger must not be an executable client endpoint.
do $$ begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke all on function public.rls_auto_enable() from public,anon,authenticated';
  end if;
end $$;
commit;
