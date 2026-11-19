import { test, before, after, beforeEach } from 'node:test';
import { setup, assertFails, assertSucceeds, ref, get, set, serverTimestamp } from './helpers.mjs';

let t;
before(async () => { t = await setup('demo-legacy'); });
after(async () => { await t.env.cleanup(); });
beforeEach(async () => { await t.env.clearDatabase(); });

test('root is closed', async () => {
  await assertFails(get(ref(t.user('alice'), '/')));
  await assertFails(set(ref(t.user('alice'), 'anything'), 1));
});

test('legacy plain-text room is frozen: verified users can read, nobody can write', async () => {
  await assertFails(get(ref(t.anon(), 'messages')));
  await assertFails(get(ref(t.user('alice', false), 'messages')));
  await assertSucceeds(get(ref(t.user('alice'), 'messages')));
  await assertFails(set(ref(t.user('alice'), 'messages/m1'), {
    senderId: 'alice', senderName: 'A', text: 'oi', timestamp: serverTimestamp(),
  }));
});
