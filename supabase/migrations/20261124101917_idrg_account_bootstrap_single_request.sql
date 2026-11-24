begin;
-- One read request instead of three separate Data API connections at login.
create function public.idrg_load_account() returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare owner_id uuid:=auth.uid(); result jsonb;
begin
  if owner_id is null then
    raise exception 'Silakan masuk terlebih dahulu.' using errcode='42501';
  end if;
  select jsonb_build_object(
    'person',(select to_jsonb(p) from public.idrg_profiles p where p.user_id=owner_id),
    'attempts',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at,a.id)
      from public.idrg_attempts a where a.user_id=owner_id),'[]'::jsonb),
    'admin',public.idrg_is_admin()
  ) into result;
  return result;
end;
$$;
revoke all on function public.idrg_load_account() from public,anon;
grant execute on function public.idrg_load_account() to authenticated;
commit;
