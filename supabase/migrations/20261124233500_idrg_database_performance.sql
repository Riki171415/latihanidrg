begin;

-- Indexes supporting question counts/grading, latest attempt lookup, account loading, and admin pagination.
create index if not exists idrg_questions_revision_packet
  on idrg_private.questions(revision, packet_id, item_id) include (case_id);
create index if not exists idrg_attempts_latest_v2
  on public.idrg_attempts(user_id, packet_id, created_at desc, id desc);
create index if not exists idrg_attempts_owner_created
  on public.idrg_attempts(user_id, created_at, id);
create index if not exists idrg_profiles_created_user
  on public.idrg_profiles(created_at desc, user_id);

-- Load the signed-in account in one security-definer read so idrg_is_admin()
-- is evaluated once instead of repeatedly across RLS row policies.
create or replace function idrg_private.idrg_load_account() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  result jsonb;
begin
  if owner_id is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode='42501';
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

revoke all on function idrg_private.idrg_load_account(), public.idrg_load_account() from public, anon;
grant execute on function idrg_private.idrg_load_account(), public.idrg_load_account() to authenticated;

-- Optimize admin dashboard: scope latest attempt scan to filtered participants,
-- avoid sorting/carrying answers JSONB for aggregate statistics, and fetch full
-- attempt payloads only for the current page.
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
    raise exception 'Akses pengelola diperlukan.' using errcode='42501';
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

commit;
