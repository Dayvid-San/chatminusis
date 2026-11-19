\set ON_ERROR_STOP 1
\set QUIET 1
-- Assertion helpers (run with the caller's role, so RLS applies).
create function t_fail(q text, expect text default null) returns void language plpgsql as $$
begin
  begin
    execute q;
  exception when others then
    if expect is not null and position(expect in sqlerrm) = 0 then
      raise exception 'wrong error for [%]: %', q, sqlerrm;
    end if;
    return;
  end;
  raise exception 'expected failure: %', q;
end $$;
create function t_count(q text, want bigint) returns void language plpgsql as $$
declare got bigint;
begin
  execute 'select count(*) from (' || q || ') s' into got;
  if got <> want then raise exception 'count % <> % for [%]', got, want, q; end if;
end $$;
grant execute on function t_fail(text, text), t_count(text, bigint) to authenticated, anon;

insert into auth.users values
  ('11111111-1111-1111-1111-111111111111', 'alice@t'), ('22222222-2222-2222-2222-222222222222', 'bob@t'),
  ('33333333-3333-3333-3333-333333333333', 'carol@t'), ('44444444-4444-4444-4444-444444444444', 'eve@t');

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'
\set C '33333333-3333-3333-3333-333333333333'
\set E '44444444-4444-4444-4444-444444444444'
\set DIRECT 'd_11111111-1111-1111-1111-111111111111_22222222-2222-2222-2222-222222222222'
\set GROUP 'g_0123456789abcdef'

-- ===== anonymous: nothing
set role anon;
select t_fail('select * from profiles');
select t_fail($$select claim_key_package('11111111-1111-1111-1111-111111111111')$$);
reset role;

-- ===== profiles
\echo profiles
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select claim_nickname('alice', 'Alice');
select t_fail($$select claim_nickname('Maiusculo', 'X')$$);
select t_fail($$select claim_nickname('ab', 'X')$$);
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_fail($$select claim_nickname('alice', 'Bob')$$, 'nickname_taken');
select claim_nickname('bob', 'Bob');
select t_count('select * from profiles', 1);                                  -- only own row: no listing
select t_count($$select * from find_profile_by_nickname('alice')$$, 1);       -- exact lookup works
select t_count($$select * from find_profile_by_nickname('ali')$$, 0);         -- no prefix search
select t_count(format('select * from get_profile(%L)', :'A'), 1);
update profiles set display_name = 'hack' where id = :'A';                     -- RLS: affects 0 rows
select t_count(format($$select * from get_profile(%L) where display_name = 'hack'$$, :'A'), 0);
-- nickname change releases the old one
select claim_nickname('bobnovo', 'Bob');
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
select claim_nickname('bob', 'Carol');
select claim_nickname('carol', 'Carol');
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select claim_nickname('eve', 'Eve');

-- ===== identity & key packages
\echo key packages
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
insert into identities (user_id, signature_key) values (:'B', 'a2V5');
select t_fail(format($$insert into identities (user_id, signature_key) values (%L, 'ZmFrZQ==')$$, :'A'));
insert into key_packages (user_id, key_package) values (:'B', 'kp1'), (:'B', 'kp2');
select t_fail(format($$insert into key_packages (user_id, key_package) values (%L, 'fake')$$, :'A'));
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count('select * from key_packages', 0);                              -- others' packages not listable
select t_count(format($$select 1 where claim_key_package(%L) = 'kp1'$$, :'B'), 1);
select t_count(format($$select 1 where claim_key_package(%L) = 'kp2'$$, :'B'), 1);
select t_count(format($$select 1 where claim_key_package(%L) is null$$, :'B'), 1);  -- single use
select t_count('select * from identities', 1);

-- ===== conversations
\echo conversations
select create_conversation(:'DIRECT', 'direct', json_build_object(:'A', 'admin', :'B', 'admin')::jsonb,
  'c1', 'Y29tbWl0', json_build_array(json_build_object('recipient', :'B', 'payload', 'd2VsY29tZQ=='))::jsonb);
select t_fail(format($$select create_conversation(%L, 'direct', '{}', 'c1', 'x', '[]')$$, :'DIRECT'), 'creator_must_be_admin');
select t_fail(format($$select create_conversation(%L, 'direct', %L, 'c1', 'x', '[]')$$, :'DIRECT',
  json_build_object(:'A', 'admin', :'B', 'admin')), 'epoch_conflict');
select t_fail(format($$select create_conversation('d_22222222-2222-2222-2222-222222222222_33333333', 'direct', %L, 'c1', 'x', '[]')$$,
  json_build_object(:'A', 'admin', :'C', 'admin')), 'invalid_direct');
-- blocked users cannot pull you in
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
insert into blocks (user_id, blocked_id) values (:'C', :'A');
select t_count('select * from blocks', 1);
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count('select * from blocks', 0);
select t_fail(format($$select create_conversation('d_11111111-1111-1111-1111-111111111111_33333333-3333-3333-3333-333333333333', 'direct', %L, 'c1', 'x', '[]')$$,
  json_build_object(:'A', 'admin', :'C', 'admin')), 'blocked');

-- group with alice (admin) and bob
select create_conversation(:'GROUP', 'group', json_build_object(:'A', 'admin', :'B', 'member')::jsonb,
  'c1', 'Y29tbWl0', json_build_array(json_build_object('recipient', :'B', 'payload', 'dw=='))::jsonb);

\echo reads
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select t_count('select * from conversations', 0);
select t_count('select * from mls_messages', 0);
select t_count('select * from conversation_members', 0);
select t_fail(format($$select publish_application(%L, 1, 'm1', 'eA==')$$, :'GROUP'), 'not_member');
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from conversations', 2);
select t_count('select * from welcomes', 2);
select t_fail($$insert into mls_messages (conversation_id, id, sender, epoch, kind, payload) values ('g_0123456789abcdef', 'x', '22222222-2222-2222-2222-222222222222', 1, 'app', 'eA==')$$);

\echo application messages
select publish_application(:'GROUP', 1, 'm1', 'Y2lwaGVy');
select t_fail(format($$select publish_application(%L, 0, 'm2', 'eA==')$$, :'GROUP'), 'stale_epoch');
select t_fail(format($$select publish_application(%L, 1, 'm1', 'eA==')$$, :'GROUP'));   -- no overwrite
select t_count($$select * from mls_messages where id = 'm1' and sender = '22222222-2222-2222-2222-222222222222'$$, 1);

\echo commits compare-and-set
select publish_commit(:'GROUP', 2, 'k1', 'eA==', '{}', '[]');
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_fail(format($$select publish_commit(%L, 2, 'k2', 'eA==', '{}', '[]')$$, :'GROUP'), 'epoch_conflict');
select t_fail(format($$select publish_commit(%L, 4, 'k3', 'eA==', '{}', '[]')$$, :'GROUP'), 'epoch_conflict');

\echo membership
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_fail(format($$select publish_commit(%L, 3, 'k4', 'eA==', %L, '[]')$$, :'GROUP', json_build_object(:'E', 'member')), 'not_admin');
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_fail(format($$select publish_commit(%L, 2, 'k5', 'eA==', %L, '[]')$$, :'DIRECT', json_build_object(:'E', 'member')), 'not_admin');
select t_fail(format($$select publish_commit(%L, 3, 'k6', 'eA==', '{}', %L)$$, :'GROUP',
  json_build_array(json_build_object('recipient', :'E', 'payload', 'dw=='))), 'welcome_for_non_member');
select publish_commit(:'GROUP', 3, 'k7', 'eA==', json_build_object(:'E', 'member')::jsonb,
  json_build_array(json_build_object('recipient', :'E', 'payload', 'dw=='))::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select t_count('select * from conversations', 1);
select t_count('select * from welcomes', 1);
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select publish_commit(:'GROUP', 4, 'k8', 'eA==', json_build_object(:'E', null)::jsonb, '[]');
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select t_count('select * from mls_messages', 0);                               -- removed: no access
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
delete from conversation_members where conversation_id = :'GROUP' and user_id = :'A';           -- RLS: 0 rows
select t_count(format($$select * from conversation_members where conversation_id = %L$$, :'GROUP'), 2);
delete from conversation_members where conversation_id = :'GROUP' and user_id = :'B';          -- leave
select t_count('select * from mls_messages where conversation_id = ''g_0123456789abcdef''', 0);
delete from welcomes;
select t_count('select * from welcomes', 0);

\echo rejoin
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
insert into rejoin_requests (conversation_id, user_id) values (:'DIRECT', :'A');
select t_fail(format($$insert into rejoin_requests (conversation_id, user_id) values (%L, %L)$$, :'DIRECT', :'B'));
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select t_fail(format($$insert into rejoin_requests (conversation_id, user_id) values (%L, %L)$$, :'DIRECT', :'E'));
select t_count('select * from rejoin_requests', 0);
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from rejoin_requests', 1);
delete from rejoin_requests where conversation_id = :'DIRECT';
select t_count('select * from rejoin_requests', 0);

\echo push and backup
insert into push_tokens (user_id, device_id, token, platform) values (:'B', 'd1', 'tok', 'android');
insert into backups (user_id, blob, size) values (:'B', 'Q01CSw==', 4);
insert into backup_shares (user_id, share) values (:'B', repeat('A', 43) || '=');
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count('select * from push_tokens', 0);
select t_count('select * from backups', 0);
select t_count('select * from backup_shares', 0);
select t_fail(format($$insert into backups (user_id, blob, size) values (%L, 'x', 1)$$, :'B'));

\echo reports
select t_fail(format($$insert into reports (reporter, reported, reason) values (%L, %L, 'spam')$$, :'B', :'C'));
insert into reports (reported, reason) values (:'C', 'spam');
select t_count('select * from reports', 0);                                    -- write-only

reset role;
\echo ALL SUPABASE RLS TESTS PASSED
