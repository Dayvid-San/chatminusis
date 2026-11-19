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
delete from key_packages where user_id = :'B';                                -- RLS: affects 0 rows
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from key_packages', 2);                              -- ...so bob still has both
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count(format($$select 1 where claim_key_package(%L) = 'kp1'$$, :'B'), 1);
select t_count(format($$select 1 where claim_key_package(%L) = 'kp2'$$, :'B'), 1);
select t_count(format($$select 1 where claim_key_package(%L) is null$$, :'B'), 1);  -- pool empty, no last resort yet
select t_count('select * from identities', 1);

\echo last resort and claim limits
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
insert into last_resort_key_packages (user_id, key_package) values (:'B', 'LAST');
select t_fail(format($$insert into last_resort_key_packages (user_id, key_package) values (%L, 'fake')$$, :'A'));
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count('select * from last_resort_key_packages', 0);                  -- private to the owner
select t_count(format($$select 1 where claim_key_package(%L) = 'LAST'$$, :'B'), 1);   -- served when the pool is empty
select t_count(format($$select 1 where claim_key_package(%L) = 'LAST'$$, :'B'), 1);   -- ...and never consumed
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from last_resort_key_packages', 1);
insert into key_packages (user_id, key_package) select :'B', 'kp' || g from generate_series(1, 30) g;
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
-- A already used 5 claims (2 above + 3 earlier) of the 10 allowed this hour.
select claim_key_package(:'B') from generate_series(1, 5);
select t_fail(format($$select claim_key_package(%L)$$, :'B'), 'rate_limited');
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from key_packages', 25);                             -- the drain stopped at the limit
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
select t_count(format($$select 1 where claim_key_package(%L) is not null$$, :'B'), 1);   -- others unaffected
select t_fail(format($$select claim_key_package(%L)$$, :'C'), 'invalid_argument');
select t_fail('select * from key_package_claims');                            -- counters are server-only
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
insert into blocks (user_id, blocked_id) values (:'B', :'E');
select set_config('request.jwt.claims', json_build_object('sub', :'E')::text, false);
select t_fail(format($$select claim_key_package(%L)$$, :'B'), 'permission_denied');
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
delete from blocks where blocked_id = :'E';
delete from key_packages;
delete from last_resort_key_packages;

-- ===== conversations
\echo conversations
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
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

\echo search limits
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
select t_fail($$select * from find_profile_by_nickname('Maiusculo')$$, 'invalid_argument');
select t_fail($$select * from find_profile_by_nickname('../x')$$, 'invalid_argument');
select t_count($$select * from find_profile_by_nickname('carol')$$, 0);              -- yourself: looks like not found
select t_count($$select * from find_profile_by_nickname('alice')$$, 1);
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
insert into blocks (user_id, blocked_id) values (:'B', :'C') on conflict do nothing;
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
select t_count($$select * from find_profile_by_nickname('bobnovo')$$, 0);            -- bob blocked carol: hidden
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count($$select * from find_profile_by_nickname('bobnovo')$$, 1);            -- others still find bob
-- Carol has made 3 valid lookups so far (invalid input is not counted); the limit is 30 per hour.
select set_config('request.jwt.claims', json_build_object('sub', :'C')::text, false);
select count(*) from (select find_profile_by_nickname('nobodyhere' || g) from generate_series(1, 27) g) x;
select t_fail($$select * from find_profile_by_nickname('alice')$$, 'rate_limited');
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count($$select * from find_profile_by_nickname('bobnovo')$$, 1);            -- per user
select t_fail('select * from search_log');                                          -- counters are server-only
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
delete from blocks where blocked_id = :'C';

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
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_count('select * from backup_shares', 0);                          -- not even the owner: only get_backup_share()
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_fail(format($$insert into backups (user_id, blob, size) values (%L, 'x', 1)$$, :'B'));

\echo backup share access
select set_config('request.jwt.claims', json_build_object('sub', :'B', 'amr',
  json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 10)))::text, false);
select t_count(format($$select 1 where get_backup_share() = %L$$, repeat('A', 43) || '='), 1);   -- fresh login: delivered
select t_count('select * from backup_downloads', 1);                                                -- ...and logged
select set_config('request.jwt.claims', json_build_object('sub', :'B', 'amr',
  json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 400)))::text, false);
select t_fail('select get_backup_share()', 'reauth_required');                                      -- login too old
select set_config('request.jwt.claims', json_build_object('sub', :'B')::text, false);
select t_fail('select get_backup_share()', 'reauth_required');                                      -- no amr at all
select t_fail($$insert into backup_downloads (user_id) values ('22222222-2222-2222-2222-222222222222')$$);
select t_fail('delete from backup_downloads');                                                      -- no privilege to erase the trail
select t_count('select * from backup_downloads', 1);                                                -- trail cannot be erased
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_count('select * from backup_downloads', 0);                                                -- private to the owner
select t_fail('select get_backup_share()', 'reauth_required');
select set_config('request.jwt.claims', json_build_object('sub', :'B', 'amr',
  json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 5)))::text, false);
select get_backup_share() from generate_series(1, 4);                                               -- 1 + 4 = 5 per hour
select t_fail('select get_backup_share()', 'rate_limited');
select t_count('select * from backup_downloads', 5);
select set_config('request.jwt.claims', json_build_object('sub', :'C', 'amr',
  json_build_array(json_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint)))::text, false);
select t_count('select 1 where get_backup_share() is null', 1);                                    -- no backup: nothing delivered
select t_count('select * from backup_downloads', 0);                                                -- ...and nothing logged

\echo reports
select set_config('request.jwt.claims', json_build_object('sub', :'A')::text, false);
select t_fail(format($$insert into reports (reporter, reported, reason) values (%L, %L, 'spam')$$, :'B', :'C'));
insert into reports (reported, reason) values (:'C', 'spam');
select t_count('select * from reports', 0);                                    -- write-only

reset role;

\echo retention
insert into mls_messages (conversation_id, id, sender, epoch, kind, payload, ts) values
  (:'GROUP', 'old-app', :'A', 1, 'app', 'eA==', now() - interval '31 days'),
  (:'GROUP', 'new-app', :'A', 1, 'app', 'eA==', now() - interval '29 days'),
  (:'GROUP', 'old-commit-31', :'A', 1, 'commit', 'eA==', now() - interval '31 days'),
  (:'GROUP', 'old-commit-181', :'A', 1, 'commit', 'eA==', now() - interval '181 days');
select prune_old_data();
select t_count($$select * from mls_messages where id = 'old-app'$$, 0);
select t_count($$select * from mls_messages where id = 'new-app'$$, 1);
select t_count($$select * from mls_messages where id = 'old-commit-31'$$, 1);   -- commits live longer
select t_count($$select * from mls_messages where id = 'old-commit-181'$$, 0);
set role authenticated;
select t_fail('select prune_old_data()');                                      -- not callable by users
reset role;
\echo ALL SUPABASE RLS TESTS PASSED
