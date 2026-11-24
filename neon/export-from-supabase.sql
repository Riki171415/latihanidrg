-- Jalankan query ini di Supabase SQL Editor (proyek lama) setelah database Supabase kembali aktif.
-- Salin teks hasil pada kolom "migration_sql", lalu jalankan di Neon SQL Editor (setelah neon/setup.sql dijalankan).
select concat_ws(
  E'\n',
  'begin;',
  coalesce((
    select string_agg(
      format(
        'insert into public.idrg_profiles(user_id, full_name, email, username, phone, institution, created_at) values (%L::uuid, %L, %L, %L, %L, %L, %L::timestamptz) on conflict do nothing;',
        user_id, full_name, email, username, phone, institution, created_at
      ),
      E'\n'
      order by created_at, user_id
    )
    from public.idrg_profiles
  ), ''),
  coalesce((
    select string_agg(
      format(
        'insert into public.idrg_attempts(id, user_id, packet_id, revision, answers, case_index, question_index, version, correct_count, total_count, submitted_at, edit_count, created_at, updated_at) values (%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::integer, %L::integer, %L::integer, %L::integer, %L::integer, %L::timestamptz, %L::smallint, %L::timestamptz, %L::timestamptz) on conflict do nothing;',
        id, user_id, packet_id, revision, answers::text, case_index, question_index, version, correct_count, total_count, submitted_at, edit_count, created_at, updated_at
      ),
      E'\n'
      order by created_at, id
    )
    from public.idrg_attempts
  ), ''),
  coalesce((
    select string_agg(
      format(
        'insert into idrg_private.attempt_history(attempt_id, round, answers, correct_count, total_count, submitted_at) values (%L::uuid, %L::smallint, %L::jsonb, %L::integer, %L::integer, %L::timestamptz) on conflict do nothing;',
        attempt_id, round, answers::text, correct_count, total_count, submitted_at
      ),
      E'\n'
      order by submitted_at, attempt_id, round
    )
    from idrg_private.attempt_history
  ), ''),
  coalesce((
    select string_agg(
      format(
        'insert into idrg_private.staff_roles(user_id, role) values (%L::uuid, %L) on conflict do nothing;',
        user_id, role
      ),
      E'\n'
      order by user_id
    )
    from idrg_private.staff_roles
  ), ''),
  coalesce((
    select string_agg(
      format(
        'insert into idrg_private.admin_allowlist(email) values (%L) on conflict do nothing;',
        email
      ),
      E'\n'
      order by email
    )
    from idrg_private.admin_allowlist
  ), ''),
  'commit;'
) as migration_sql;
