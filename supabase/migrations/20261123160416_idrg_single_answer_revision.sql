begin;
alter table public.idrg_attempts add column edit_count smallint not null default 0 check(edit_count between 0 and 1);
create table idrg_private.attempt_history (
  attempt_id uuid not null references public.idrg_attempts(id) on delete cascade,
  round smallint not null check(round between 0 and 1),
  answers jsonb not null,
  correct_count integer not null,
  total_count integer not null,
  submitted_at timestamptz not null,
  primary key(attempt_id,round)
);
alter table idrg_private.attempt_history enable row level security;
revoke all on idrg_private.attempt_history from public,anon,authenticated;

create or replace function idrg_private.idrg_submit_attempt(p_id uuid,p_answers jsonb,p_version integer)
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
  insert into idrg_private.attempt_history(attempt_id,round,answers,correct_count,total_count,submitted_at)
    values(attempt.id,attempt.edit_count,attempt.answers,attempt.correct_count,attempt.total_count,attempt.submitted_at)
    on conflict(attempt_id,round) do nothing;
  return to_jsonb(attempt);
end;
$$;

create function idrg_private.idrg_reopen_attempt(p_id uuid,p_version integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare attempt public.idrg_attempts;
begin
  select * into attempt from public.idrg_attempts where id=p_id and user_id=auth.uid() for update;
  if not found then raise exception 'Latihan tidak ditemukan.' using errcode='42501'; end if;
  if attempt.edit_count=1 and attempt.submitted_at is null then return to_jsonb(attempt); end if;
  if attempt.submitted_at is null then raise exception 'Paket belum dikirim.'; end if;
  if attempt.edit_count>=1 then raise exception 'Kesempatan revisi satu kali sudah digunakan.'; end if;
  if p_version is null or p_version<>attempt.version then raise exception 'Data berubah pada perangkat lain. Muat ulang terlebih dahulu.' using errcode='40001'; end if;
  insert into idrg_private.attempt_history(attempt_id,round,answers,correct_count,total_count,submitted_at)
    values(attempt.id,0,attempt.answers,attempt.correct_count,attempt.total_count,attempt.submitted_at)
    on conflict(attempt_id,round) do nothing;
  update public.idrg_attempts set edit_count=1,correct_count=null,submitted_at=null,
    case_index=0,question_index=0,version=version+1,updated_at=now() where id=p_id returning * into attempt;
  return to_jsonb(attempt);
end;
$$;
create function public.idrg_reopen_attempt(p_id uuid,p_version integer) returns jsonb
language sql volatile security invoker set search_path='' as $$ select idrg_private.idrg_reopen_attempt(p_id,p_version); $$;

create function idrg_private.idrg_attempt_history(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.idrg_attempts a where a.id=p_id and (a.user_id=auth.uid() or public.idrg_is_admin())) then
    raise exception 'Riwayat tidak dapat diakses.' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.round),'[]'::jsonb) into result
    from idrg_private.attempt_history h where h.attempt_id=p_id;
  return result;
end;
$$;
create function public.idrg_attempt_history(p_id uuid) returns jsonb
language sql stable security invoker set search_path='' as $$ select idrg_private.idrg_attempt_history(p_id); $$;
revoke all on function idrg_private.idrg_reopen_attempt(uuid,integer),idrg_private.idrg_attempt_history(uuid),
 public.idrg_reopen_attempt(uuid,integer),public.idrg_attempt_history(uuid) from public,anon;
grant execute on function idrg_private.idrg_reopen_attempt(uuid,integer),idrg_private.idrg_attempt_history(uuid),
 public.idrg_reopen_attempt(uuid,integer),public.idrg_attempt_history(uuid) to authenticated;
commit;
