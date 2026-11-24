begin;
create or replace function idrg_private.idrg_admin_dashboard(p_search text default '',p_institution text default '',p_page integer default 0,p_page_size integer default 25)
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
    order by a.user_id,a.packet_id,a.created_at desc,a.id desc
  ), page_rows as (
    select f.*,coalesce((select jsonb_agg(to_jsonb(a) order by a.packet_id) from latest a where a.user_id=f.user_id),'[]'::jsonb) attempts
    from filtered f order by f.created_at desc,f.user_id
    limit greatest(1,least(p_page_size,100)) offset greatest(0,p_page)*greatest(1,least(p_page_size,100))
  ) select jsonb_build_object(
    'participants',(select count(*) from filtered),
    'submitted',(select count(*) from latest a join filtered f on f.user_id=a.user_id where a.submitted_at is not null),
    'average',(select round(100.0*sum(a.correct_count)/nullif(sum(a.total_count),0),1) from latest a join filtered f on f.user_id=a.user_id where a.submitted_at is not null),
    'materials',coalesce((select jsonb_agg(to_jsonb(m) order by m.packet_id) from (
      select a.packet_id,count(*) submitted,
        round(avg(100.0*a.correct_count/nullif(a.total_count,0)),1) average
      from latest a join filtered f on f.user_id=a.user_id
      where a.submitted_at is not null group by a.packet_id
    ) m),'[]'::jsonb),
    'rows',coalesce((select jsonb_agg(to_jsonb(p)) from page_rows p),'[]'::jsonb),
    'institutions',coalesce((select jsonb_agg(t.institution) from (select distinct institution from public.idrg_profiles order by institution) t),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;
commit;
