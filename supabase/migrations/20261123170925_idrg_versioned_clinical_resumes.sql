begin;
-- Keep the legacy one-argument RPC for browsers opened before this release.
create function idrg_private.idrg_start_packet_versioned(p_packet_id text,p_revision text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); total integer; attempt public.idrg_attempts;
begin
  if uid is null then raise exception 'Silakan masuk terlebih dahulu.' using errcode='42501'; end if;
  if p_revision is null or not exists(select 1 from idrg_private.bank_versions where revision=p_revision) then
    raise exception 'Versi soal belum tersedia. Muat ulang aplikasi.';
  end if;
  select count(*) into total from idrg_private.questions where revision=p_revision and packet_id=p_packet_id;
  if total=0 then raise exception 'Paket latihan belum tersedia.'; end if;
  insert into public.idrg_attempts(user_id,packet_id,revision,total_count)
    values(uid,p_packet_id,p_revision,total) on conflict(user_id,packet_id,revision) do nothing;
  select * into attempt from public.idrg_attempts where user_id=uid and packet_id=p_packet_id and revision=p_revision;
  return to_jsonb(attempt);
end;
$$;
create function public.idrg_start_packet_versioned(p_packet_id text,p_revision text)
returns jsonb language sql volatile security invoker set search_path = '' as $$
  select idrg_private.idrg_start_packet_versioned(p_packet_id,p_revision);
$$;
revoke all on function public.idrg_start_packet_versioned(text,text),
 idrg_private.idrg_start_packet_versioned(text,text) from public,anon;
grant execute on function public.idrg_start_packet_versioned(text,text),
 idrg_private.idrg_start_packet_versioned(text,text) to authenticated;
commit;
