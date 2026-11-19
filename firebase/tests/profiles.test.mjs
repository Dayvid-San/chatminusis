import { test, before, after, beforeEach } from 'node:test';
import { setup, assertFails, assertSucceeds, ref, get, set, update, push, serverTimestamp } from './helpers.mjs';

let t;
before(async () => { t = await setup('demo-profiles'); });
after(async () => { await t.env.cleanup(); });
beforeEach(async () => { await t.env.clearDatabase(); });

const claim = (uid, nick, extra = {}) => ({
  [`nicknames/${nick}`]: uid,
  [`users/${uid}/nickname`]: nick,
  [`users/${uid}/displayName`]: 'Nome',
  [`users/${uid}/createdAt`]: serverTimestamp(),
  ...extra,
});

test('claim a nickname atomically', async () => {
  await assertSucceeds(update(ref(t.user('alice')), claim('alice', 'alice_01')));
});

test('unverified user cannot claim', async () => {
  await assertFails(update(ref(t.user('alice', false)), claim('alice', 'alice_01')));
});

test('nickname cannot be taken twice, even atomically', async () => {
  await update(ref(t.user('alice')), claim('alice', 'dono'));
  await assertFails(update(ref(t.user('bob')), claim('bob', 'dono')));
  await assertFails(set(ref(t.user('bob'), 'nicknames/dono'), 'bob'));
});

test('cannot claim without the matching profile, or with invalid format', async () => {
  await assertFails(set(ref(t.user('alice'), 'nicknames/solto'), 'alice'));
  await assertFails(update(ref(t.user('alice')), claim('alice', 'Maiusculo')));
  await assertFails(update(ref(t.user('alice')), claim('alice', 'ab')));
  await assertFails(update(ref(t.user('alice')), claim('alice', 'tem espaco')));
});

test('profile nickname must point to a nickname owned by the user', async () => {
  await update(ref(t.user('bob')), claim('bob', 'bobnick'));
  await update(ref(t.user('alice')), claim('alice', 'alicenick'));
  await assertFails(set(ref(t.user('alice'), 'users/alice/nickname'), 'bobnick'));
});

test('cannot write another user profile or extra fields', async () => {
  await assertFails(update(ref(t.user('mallory')), claim('alice', 'alicenick')));
  await update(ref(t.user('alice')), claim('alice', 'alicenick'));
  await assertFails(set(ref(t.user('alice'), 'users/alice/email'), 'a@b.com'));
  await assertFails(set(ref(t.user('alice'), 'users/alice/displayName'), 'x'.repeat(31)));
  await assertSucceeds(set(ref(t.user('alice'), 'users/alice/displayName'), 'Alice'));
});

test('change nickname releases the old one; cannot release while still using it', async () => {
  await update(ref(t.user('alice')), claim('alice', 'velho'));
  await assertFails(set(ref(t.user('alice'), 'nicknames/velho'), null));
  await assertSucceeds(update(ref(t.user('alice')), {
    'nicknames/novo': 'alice', 'nicknames/velho': null, 'users/alice/nickname': 'novo',
  }));
  await assertSucceeds(update(ref(t.user('bob')), claim('bob', 'velho')));
});

test('cannot delete someone else nickname', async () => {
  await update(ref(t.user('alice')), claim('alice', 'alicenick'));
  await assertFails(set(ref(t.user('bob'), 'nicknames/alicenick'), null));
});

test('exact lookup works but listing users or nicknames does not', async () => {
  await update(ref(t.user('alice')), claim('alice', 'alicenick'));
  const db = t.user('bob');
  await assertSucceeds(get(ref(db, 'nicknames/alicenick')));
  await assertSucceeds(get(ref(db, 'users/alice')));
  await assertFails(get(ref(db, 'nicknames')));
  await assertFails(get(ref(db, 'users')));
  await assertFails(get(ref(t.anon(), 'nicknames/alicenick')));
  await assertFails(get(ref(t.user('carol', false), 'users/alice')));
});

test('blocks are private to their owner', async () => {
  await assertSucceeds(set(ref(t.user('alice'), 'blocks/alice/bob'), true));
  await assertSucceeds(get(ref(t.user('alice'), 'blocks/alice')));
  await assertFails(get(ref(t.user('bob'), 'blocks/alice')));
  await assertFails(set(ref(t.user('bob'), 'blocks/alice/carol'), true));
  await assertFails(set(ref(t.user('alice'), 'blocks/alice/alice'), true));
  await assertFails(set(ref(t.user('alice'), 'blocks/alice/bob'), 'sim'));
});

test('reports are write-only and signed by the reporter', async () => {
  const report = (reporter, reported) => ({ reporter, reported, reason: 'spam', createdAt: serverTimestamp() });
  const db = t.user('alice');
  await assertSucceeds(set(push(ref(db, 'reports')), report('alice', 'bob')));
  await assertFails(set(push(ref(db, 'reports')), report('bob', 'carol')));
  await assertFails(set(push(ref(db, 'reports')), report('alice', 'alice')));
  await assertFails(get(ref(db, 'reports')));
});
