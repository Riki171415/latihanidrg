import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const db = new PGlite();
const uid1 = '11111111-1111-4111-8111-111111111111';
const uid2 = '22222222-2222-4222-8222-222222222222';
const uid3 = '33333333-3333-4333-8333-333333333333';

try {
  await db.exec(`
    create schema neon_auth;
    create role anon;
    create role anonymous;
    create role authenticated;
    create table neon_auth."user"(
      id uuid primary key,
      email text not null,
      name text,
      "emailVerified" boolean not null default false
    );
    grant usage on schema public to anon, anonymous, authenticated;
  `);

  const setupSql = await fs.readFile(new URL('../neon/setup.sql', import.meta.url), 'utf8');
  await db.exec(setupSql);

  await db.query('insert into neon_auth."user" values ($1, $2, $3, false)', [uid1, 'one@example.test', 'User One']);
  await db.query('insert into neon_auth."user" values ($1, $2, $3, true)', [uid2, 'two@example.test', 'User Two']);

  const login = async (uid, useClaimsJson = false) => {
    await db.exec('reset role');
    if (useClaimsJson) {
      await db.query("select set_config('request.jwt.claim.sub', '', false)");
      await db.query("select set_config('request.jwt.claims', $1, false)", [JSON.stringify({sub: uid, email: 'claim@example.test'})]);
    } else {
      await db.query("select set_config('request.jwt.claims', '', false)");
      await db.query("select set_config('request.jwt.claim.sub', $1, false)", [uid]);
    }
    await db.exec('set role authenticated');
  };

  const rpc = async (name, args = []) => {
    const placeholders = args.map((_, i) => '$' + (i + 1)).join(',');
    return (await db.query(`select public.${name}(${placeholders}) as value`, args)).rows[0].value;
  };

  // Anonymous access must be rejected on both anon and anonymous roles.
  for (const roleName of ['anon', 'anonymous']) {
    await db.exec(`reset role; set role ${roleName}`);
    await assert.rejects(db.query('select * from public.idrg_profiles'));
    await assert.rejects(db.query('select * from public.idrg_attempts'));
    await assert.rejects(rpc('idrg_load_account'));
    await assert.rejects(rpc('idrg_start_packet', ['4']));
    await assert.rejects(rpc('idrg_start_packet_versioned', ['4', '2026-11-24.1']));
  }

  // First login before profile exists, then complete profile.
  await login(uid1);
  const initialAccount = await rpc('idrg_load_account');
  assert.equal(initialAccount.person, null);
  assert.deepEqual(initialAccount.attempts, []);
  assert.equal(initialAccount.admin, false);

  const created = await rpc('idrg_complete_profile', ['Neon Test One', 'neon_user_one', '08123456789', 'RS Umum']);
  assert.equal(created.user_id, uid1);
  assert.equal(created.email, 'one@example.test');
  assert.equal(created.username, 'neon_user_one');

  // JWT claims JSON fallback when neon_auth."user" lacks a row (uid3).
  await login(uid3, true);
  const uid3Profile = await rpc('idrg_complete_profile', ['JWT Claim User', 'jwt_claim_user', '08123456780', 'RS Claim']);
  assert.equal(uid3Profile.email, 'claim@example.test');
  assert.equal((await rpc('idrg_load_account')).person.user_id, uid3);

  // Switch back to uid1 and run packet lifecycle, grading, revision, and isolation checks.
  await login(uid1);
  await assert.rejects(db.query('select * from idrg_private.questions'));
  await assert.rejects(rpc('idrg_admin_dashboard'));

  const attempt = await rpc('idrg_start_packet_versioned', ['2-casemix', '2026-11-24.1']);
  assert.equal(attempt.total_count, 8);
  await assert.rejects(rpc('idrg_review', [attempt.id]));
  await assert.rejects(db.query('update public.idrg_attempts set correct_count=8 where id=$1', [attempt.id]));
  await assert.rejects(rpc('idrg_save_attempt', [attempt.id, {'M4-01-0': '0'}, 0, 0, 0]));
  await assert.rejects(rpc('idrg_save_attempt', [attempt.id, {'M2-01-0': '5'}, 0, 0, 0]));

  const saved = await rpc('idrg_save_attempt', [attempt.id, {'M2-01-0': '4'}, 0, 1, 0]);
  assert.equal(saved.version, 1);
  await assert.rejects(rpc('idrg_save_attempt', [attempt.id, {}, 0, 0, 0]));

  // Owner isolation from uid2.
  await login(uid2);
  await rpc('idrg_complete_profile', ['Neon Test Two', 'neon_user_two', '08123456799', 'RS Khusus']);
  assert.equal((await db.query('select * from public.idrg_attempts')).rows.length, 0);
  await assert.rejects(rpc('idrg_save_attempt', [attempt.id, {}, 0, 0, 1]));
  await assert.rejects(rpc('idrg_submit_attempt', [attempt.id, {}, 1]));

  // Grade, submit, reopen once, resubmit, verify history.
  await login(uid1);
  const bank = JSON.parse(await fs.readFile(new URL('../src/cases.json', import.meta.url), 'utf8'));
  const answers = Object.fromEntries(bank.slice(0, 2).flatMap(c => c.items.map((q, i) => [c.id + '-' + i, String(q.correct)])));
  answers['M2-01-0'] = String((bank[0].items[0].correct + 1) % 5);
  delete answers['M2-01-1'];

  const finished = await rpc('idrg_submit_attempt', [attempt.id, answers, 1]);
  assert.equal(finished.correct_count, 6);
  assert.equal(finished.total_count, 8);
  assert(finished.submitted_at);
  assert.equal((await rpc('idrg_review', [attempt.id])).length, 8);
  assert.equal((await rpc('idrg_submit_attempt', [attempt.id, {}, 1])).correct_count, 6);

  const reopened = await rpc('idrg_reopen_attempt', [attempt.id, finished.version]);
  assert.equal(reopened.edit_count, 1);
  assert.equal(reopened.submitted_at, null);
  const allRight = Object.fromEntries(bank.slice(0, 2).flatMap(c => c.items.map((q, i) => [c.id + '-' + i, String(q.correct)])));
  const revised = await rpc('idrg_submit_attempt', [attempt.id, allRight, reopened.version]);
  assert.equal(revised.correct_count, 8);
  await assert.rejects(rpc('idrg_reopen_attempt', [attempt.id, revised.version]));
  assert.deepEqual((await rpc('idrg_attempt_history', [attempt.id])).map(h => h.correct_count), [6, 8]);

  // Admin verification via staff_roles and admin_allowlist.
  await db.exec('reset role');
  await db.query("insert into idrg_private.staff_roles values ($1, 'admin')", [uid2]);
  await login(uid2);
  assert.equal(await rpc('idrg_is_admin'), true);
  assert.equal((await rpc('idrg_load_account')).admin, true);

  const dashboard = await rpc('idrg_admin_dashboard', ['', '', 0, 25]);
  assert.equal(dashboard.participants, 3);
  assert.equal(dashboard.submitted, 1);
  assert.equal(Number(dashboard.average), 100);
  assert.deepEqual(dashboard.materials, [{packet_id: '2-casemix', submitted: 1, average: 100}]);
  assert.equal((await rpc('idrg_admin_dashboard', ['Neon Test One', 'RS Umum', 0, 25])).participants, 1);

  await db.exec('reset role');
  await db.query("insert into idrg_private.admin_allowlist values ('one@example.test')");
  await login(uid1);
  assert.equal(await rpc('idrg_is_admin'), true);

  console.log('PASS: Neon PostgreSQL schema, JWT claims, RLS isolation, server grading, revision history, and admin dashboard.');
} finally {
  await db.close();
}
