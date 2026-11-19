import { test, before, after, beforeEach } from 'node:test';
import { setup, assertFails, assertSucceeds, ref, get, set, serverTimestamp } from './helpers.mjs';

let t;
before(async () => { t = await setup('demo-legacy'); });
after(async () => { await t.env.cleanup(); });
beforeEach(async () => { await t.env.clearDatabase(); });

const msg = (uid, extra = {}) => ({ senderId: uid, senderName: 'Ana', text: 'oi', timestamp: serverTimestamp(), ...extra });

test('root is closed', async () => {
  await assertFails(get(ref(t.user('alice'), '/')));
  await assertFails(set(ref(t.user('alice'), 'anything'), 1));
});

test('anonymous and unverified users cannot read or write', async () => {
  await assertFails(get(ref(t.anon(), 'messages')));
  await assertFails(get(ref(t.user('alice', false), 'messages')));
  await assertFails(set(ref(t.user('alice', false), 'messages/m1'), msg('alice')));
});

test('verified user can read and post as themselves', async () => {
  await assertSucceeds(get(ref(t.user('alice'), 'messages')));
  await assertSucceeds(set(ref(t.user('alice'), 'messages/m1'), msg('alice')));
});

test('cannot impersonate, add fields, fake timestamps or edit', async () => {
  const db = t.user('alice');
  await assertFails(set(ref(db, 'messages/m1'), msg('bob')));
  await assertFails(set(ref(db, 'messages/m2'), msg('alice', { admin: true })));
  await assertFails(set(ref(db, 'messages/m3'), msg('alice', { timestamp: 123 })));
  await assertFails(set(ref(db, 'messages/m4'), msg('alice', { text: 'x'.repeat(4001) })));
  await assertSucceeds(set(ref(db, 'messages/m5'), msg('alice')));
  await assertFails(set(ref(db, 'messages/m5'), msg('alice', { text: 'editado' })));
  await assertFails(set(ref(db, 'messages/m5'), null));
});
