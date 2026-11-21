import { test, before, after, beforeEach } from 'node:test';
import { setup, assertFails, ref, get, set, serverTimestamp } from './helpers.mjs';

let t;
before(async () => { t = await setup('demo-legacy'); });
after(async () => { await t.env.cleanup(); });
beforeEach(async () => { await t.env.clearDatabase(); });

test('root is closed', async () => {
  await assertFails(get(ref(t.user('alice'), '/')));
  await assertFails(set(ref(t.user('alice'), 'anything'), 1));
});

test('R8: the legacy plain-text room is closed to everyone, even while old data may still exist', async () => {
  await t.seed('messages/m1', { senderId: 'a', senderName: 'A', text: 'segredo antigo', timestamp: 1 });
  await assertFails(get(ref(t.user('alice'), 'messages')));
  await assertFails(get(ref(t.user('alice'), 'messages/m1')));
  await assertFails(get(ref(t.anon(), 'messages')));
  await assertFails(set(ref(t.user('alice'), 'messages/m2'), {
    senderId: 'alice', senderName: 'A', text: 'oi', timestamp: serverTimestamp(),
  }));
});
