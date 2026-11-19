import { test, before, after, beforeEach } from 'node:test';
import { setup, assertFails, assertSucceeds, ref, get, set, update, serverTimestamp, runTransaction } from './helpers.mjs';

let t;
before(async () => { t = await setup('demo-conversations'); });
after(async () => { await t.env.cleanup(); });
beforeEach(async () => { await t.env.clearDatabase(); });

const TS = () => serverTimestamp();
const env = (sender, epoch, kind = 'app', payload = 'Y2lwaGVy') => ({ sender, epoch, kind, payload, ts: TS() });

/** Atomic creation: conversation + first commit + welcomes + membership index. */
function creation(cid, creator, members, type = cid.startsWith('d_') ? 'direct' : 'group') {
  const u = {
    [`conversations/${cid}`]: { type, createdBy: creator, createdAt: TS(), epoch: 1, members },
    [`mlsMessages/${cid}/c1`]: env(creator, 1, 'commit'),
  };
  for (const m of Object.keys(members)) {
    u[`userConversations/${m}/${cid}`] = { since: TS() };
    if (m !== creator) u[`welcomes/${m}/w_${m}`] = { cid, from: creator, epoch: 1, payload: 'd2VsY29tZQ==', ts: TS() };
  }
  return u;
}

const DIRECT = 'd_alice_bob';
const GROUP = 'g_0123456789abcdef';

async function makeGroup() {
  await update(ref(t.user('alice')), creation(GROUP, 'alice', { alice: 'admin', bob: 'member' }));
}

test('create a direct conversation atomically', async () => {
  await assertSucceeds(update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' })));
  await assertSucceeds(get(ref(t.user('bob'), `conversations/${DIRECT}`)));
  await assertSucceeds(get(ref(t.user('bob'), `welcomes/bob`)));
  await assertSucceeds(get(ref(t.user('bob'), `userConversations/bob`)));
});

test('cannot create a conversation twice or for other people', async () => {
  await update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' }));
  await assertFails(update(ref(t.user('bob')), creation(DIRECT, 'bob', { alice: 'admin', bob: 'admin' })));
  await assertFails(update(ref(t.user('mallory')), creation('d_bob_carol', 'mallory', { mallory: 'admin', bob: 'admin' })));
  await assertFails(update(ref(t.user('alice')), creation('d_alice_carol', 'alice', { alice: 'member', carol: 'admin' })));
  await assertFails(update(ref(t.user('alice', false)), creation('d_alice_dave', 'alice', { alice: 'admin', dave: 'admin' })));
});

test('blocked users cannot pull you into conversations', async () => {
  await set(ref(t.user('bob'), 'blocks/bob/alice'), true);
  await assertFails(update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' })));
});

test('only members read conversations and messages', async () => {
  await makeGroup();
  await assertFails(get(ref(t.user('eve'), `conversations/${GROUP}`)));
  await assertFails(get(ref(t.user('eve'), `mlsMessages/${GROUP}`)));
  await assertFails(get(ref(t.user('eve'), 'conversations')));
  await assertSucceeds(get(ref(t.user('bob'), `mlsMessages/${GROUP}`)));
});

test('application messages must use the current epoch and the real sender', async () => {
  await makeGroup();
  const bob = t.user('bob');
  await assertSucceeds(set(ref(bob, `mlsMessages/${GROUP}/m1`), env('bob', 1)));
  await assertFails(set(ref(bob, `mlsMessages/${GROUP}/m2`), env('bob', 0)));
  await assertFails(set(ref(bob, `mlsMessages/${GROUP}/m3`), env('alice', 1)));
  await assertFails(set(ref(bob, `mlsMessages/${GROUP}/m1`), env('bob', 1, 'app', 'b3V0cm8=')));
  await assertFails(set(ref(t.user('eve'), `mlsMessages/${GROUP}/m4`), env('eve', 1)));
  await assertFails(set(ref(bob, `mlsMessages/${GROUP}/m5`), { ...env('bob', 1), extra: true }));
});

test('commits need an epoch compare-and-set: only one wins (two admins racing)', async () => {
  // Both creators of a direct chat are admins, so either may commit.
  await update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' }));
  const commit = (who, id, epoch) => ({ [`conversations/${DIRECT}/epoch`]: epoch, [`mlsMessages/${DIRECT}/${id}`]: env(who, epoch, 'commit') });
  await assertSucceeds(update(ref(t.user('bob')), commit('bob', 'k1', 2)));
  await assertFails(update(ref(t.user('alice')), commit('alice', 'k2', 2)), 'same epoch loses');
  await assertFails(update(ref(t.user('alice')), commit('alice', 'k3', 4)), 'cannot skip');
  await assertFails(set(ref(t.user('alice'), `mlsMessages/${DIRECT}/k4`), env('alice', 2, 'commit')), 'must bump epoch');
  await assertFails(set(ref(t.user('alice'), `conversations/${DIRECT}/epoch`), 1), 'cannot go back');
  await assertSucceeds(update(ref(t.user('alice')), commit('alice', 'k5', 3)));
});

test('only admins add members, atomically with commit, welcome and index', async () => {
  await makeGroup();
  const add = (who, id) => ({
    [`conversations/${GROUP}/epoch`]: 2,
    [`mlsMessages/${GROUP}/${id}`]: env(who, 2, 'commit'),
    [`conversations/${GROUP}/members/carol`]: 'member',
    [`userConversations/carol/${GROUP}`]: { since: TS() },
    [`welcomes/carol/${id}`]: { cid: GROUP, from: who, epoch: 2, payload: 'dw==', ts: TS() },
  });
  await assertFails(update(ref(t.user('bob')), add('bob', 'x1')));
  await assertSucceeds(update(ref(t.user('alice')), add('alice', 'x2')));
  await assertSucceeds(get(ref(t.user('carol'), `mlsMessages/${GROUP}`)));
});

test('direct conversations cannot gain members', async () => {
  await update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' }));
  await assertFails(set(ref(t.user('alice'), `conversations/${DIRECT}/members/carol`), 'member'));
});

test('removal: admin removes, removed member loses access; non-admins cannot remove others', async () => {
  await update(ref(t.user('alice')), creation(GROUP, 'alice', { alice: 'admin', bob: 'member', carol: 'member' }));
  await assertFails(set(ref(t.user('bob'), `conversations/${GROUP}/members/carol`), null));
  await assertSucceeds(update(ref(t.user('alice')), {
    [`conversations/${GROUP}/epoch`]: 2,
    [`mlsMessages/${GROUP}/r1`]: env('alice', 2, 'commit'),
    [`conversations/${GROUP}/members/carol`]: null,
    [`userConversations/carol/${GROUP}`]: null,
  }));
  await assertFails(get(ref(t.user('carol'), `mlsMessages/${GROUP}`)));
  await assertFails(get(ref(t.user('carol'), `conversations/${GROUP}`)));
});

test('members can leave by themselves', async () => {
  await makeGroup();
  await assertSucceeds(update(ref(t.user('bob')), {
    [`conversations/${GROUP}/members/bob`]: null,
    [`userConversations/bob/${GROUP}`]: null,
  }));
  await assertFails(get(ref(t.user('bob'), `mlsMessages/${GROUP}`)));
});

test('membership index cannot be forged', async () => {
  await makeGroup();
  await assertFails(set(ref(t.user('eve'), `userConversations/eve/${GROUP}`), { since: TS() }));
  await assertFails(set(ref(t.user('bob'), `userConversations/carol/${GROUP}`), { since: TS() }));
  await assertFails(get(ref(t.user('bob'), 'userConversations/alice')));
});

test('welcomes: only members invite members; recipient reads and deletes', async () => {
  await makeGroup();
  await assertFails(set(ref(t.user('eve'), 'welcomes/bob/x'), { cid: GROUP, from: 'eve', epoch: 1, payload: 'dw==', ts: TS() }));
  await assertFails(set(ref(t.user('alice'), 'welcomes/eve/x'), { cid: GROUP, from: 'alice', epoch: 1, payload: 'dw==', ts: TS() }));
  await assertFails(get(ref(t.user('alice'), 'welcomes/bob')));
  await assertSucceeds(set(ref(t.user('bob'), 'welcomes/bob/w_bob'), null));
});

test('key packages: only the owner reads, writes and deletes (others go through the claim function)', async () => {
  await assertSucceeds(set(ref(t.user('bob'), 'keyPackages/bob/k1'), 'a3Ax'));
  await assertSucceeds(set(ref(t.user('bob'), 'keyPackages/bob/k2'), 'a3Ay'));
  await assertSucceeds(get(ref(t.user('bob'), 'keyPackages/bob')));
  await assertFails(set(ref(t.user('mallory'), 'keyPackages/bob/k3'), 'ZmFrZQ=='));
  await assertFails(set(ref(t.user('mallory'), 'keyPackages/bob/k1'), 'ZmFrZQ=='));
  await assertFails(runTransaction(ref(t.user('mallory'), 'keyPackages/bob/k1'), () => null), 'cannot drain bob');
  await assertFails(set(ref(t.user('mallory'), 'keyPackages/bob/k1'), null));
  await assertFails(get(ref(t.user('mallory'), 'keyPackages/bob')));
  await assertFails(get(ref(t.anon(), 'keyPackages/bob')));
  await assertSucceeds(get(ref(t.user('bob'), 'keyPackages/bob/k1')));
});

test('last-resort key package: owner only', async () => {
  const lr = { keyPackage: 'bGFzdA==', updatedAt: TS() };
  await assertSucceeds(set(ref(t.user('bob'), 'lastResortKeyPackage/bob'), lr));
  await assertFails(set(ref(t.user('mallory'), 'lastResortKeyPackage/bob'), lr));
  await assertFails(get(ref(t.user('mallory'), 'lastResortKeyPackage/bob')));
  await assertSucceeds(get(ref(t.user('bob'), 'lastResortKeyPackage/bob')));
});

test('rate-limit counters are not reachable by clients', async () => {
  await assertFails(set(ref(t.user('alice'), 'rateLimits/kpClaim/alice/bob'), { start: 0, count: 0 }));
  await assertFails(get(ref(t.user('alice'), 'rateLimits')));
});

test('identity keys: public to verified users, written only by the owner', async () => {
  await assertSucceeds(set(ref(t.user('bob'), 'identity/bob'), { signatureKey: 'a2V5', updatedAt: TS() }));
  await assertFails(set(ref(t.user('mallory'), 'identity/bob'), { signatureKey: 'ZmFrZQ==', updatedAt: TS() }));
  await assertSucceeds(get(ref(t.user('alice'), 'identity/bob')));
  await assertFails(get(ref(t.user('alice', false), 'identity/bob')));
});

test('rejoin requests: only the member asks for themselves; members clear them', async () => {
  await makeGroup();
  await assertSucceeds(set(ref(t.user('bob'), `conversations/${GROUP}/rejoin/bob`), true));
  await assertFails(set(ref(t.user('bob'), `conversations/${GROUP}/rejoin/alice`), true));
  await assertFails(set(ref(t.user('eve'), `conversations/${GROUP}/rejoin/eve`), true));
  await assertFails(set(ref(t.user('eve'), `conversations/${GROUP}/rejoin/bob`), null));
  await assertSucceeds(set(ref(t.user('alice'), `conversations/${GROUP}/rejoin/bob`), null));
});

// ------------------------------------------------------------------ R3
// Only admins publish commits and advance the epoch; ordinary members may send
// messages and proposals (a member's own key-rotation request).

test('R3: an ordinary member cannot publish a commit or advance the epoch', async () => {
  await makeGroup(); // alice admin, bob member
  const commit = (who, id, epoch) => ({ [`conversations/${GROUP}/epoch`]: epoch, [`mlsMessages/${GROUP}/${id}`]: env(who, epoch, 'commit') });
  await assertFails(update(ref(t.user('bob')), commit('bob', 'evil1', 2)), 'bob is not an admin');
  await assertFails(set(ref(t.user('bob'), `conversations/${GROUP}/epoch`), 2), 'cannot bump the epoch alone either');
  await assertFails(set(ref(t.user('bob'), `mlsMessages/${GROUP}/evil2`), env('bob', 2, 'commit')));
  // The admin still can.
  await assertSucceeds(update(ref(t.user('alice')), commit('alice', 'ok1', 2)));
});

test('R3: ordinary members can send proposals for the current epoch only', async () => {
  await makeGroup();
  await assertSucceeds(set(ref(t.user('bob'), `mlsMessages/${GROUP}/p1`), env('bob', 1, 'proposal')));
  await assertFails(set(ref(t.user('bob'), `mlsMessages/${GROUP}/p2`), env('bob', 0, 'proposal')), 'stale epoch');
  await assertFails(set(ref(t.user('bob'), `mlsMessages/${GROUP}/p3`), env('alice', 1, 'proposal')), 'sender must be the caller');
  await assertFails(set(ref(t.user('eve'), `mlsMessages/${GROUP}/p4`), env('eve', 1, 'proposal')), 'not a member');
  await assertFails(set(ref(t.user('bob'), `mlsMessages/${GROUP}/p5`), { ...env('bob', 1, 'proposal'), kind: 'other' }));
});

test('R3: in a direct chat both people are admins and can rotate keys with a commit', async () => {
  await update(ref(t.user('alice')), creation(DIRECT, 'alice', { alice: 'admin', bob: 'admin' }));
  const commit = (who, id, epoch) => ({ [`conversations/${DIRECT}/epoch`]: epoch, [`mlsMessages/${DIRECT}/${id}`]: env(who, epoch, 'commit') });
  await assertSucceeds(update(ref(t.user('bob')), commit('bob', 'r1', 2)));
  await assertSucceeds(update(ref(t.user('alice')), commit('alice', 'r2', 3)));
});

test('R3: demoting a member keeps them out of commits', async () => {
  await update(ref(t.user('alice')), creation(GROUP, 'alice', { alice: 'admin', bob: 'member', carol: 'member' }));
  await assertFails(update(ref(t.user('carol')), {
    [`conversations/${GROUP}/epoch`]: 2,
    [`mlsMessages/${GROUP}/c1`]: env('carol', 2, 'commit'),
    [`conversations/${GROUP}/members/bob`]: null,
    [`userConversations/bob/${GROUP}`]: null,
  }), 'removing someone through a commit needs admin rights');
});
