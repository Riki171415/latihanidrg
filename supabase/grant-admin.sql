-- Project owner only. The account becomes admin after registration and activation by Supabase Auth.
insert into idrg_private.admin_allowlist(email) values (lower('GANTI_DENGAN_EMAIL_ADMIN')) on conflict(email) do nothing;
