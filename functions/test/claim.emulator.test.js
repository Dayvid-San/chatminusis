import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { claimKeyPackageCore, bumpWindow, KP_CLAIMS_PER_HOUR, ServiceError } from '../core.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
beforeEach(async () => { await db.ref().set(null); });
after(() => closeDb());

const seed = (target, packages, lastResort) =>
  db.ref().update({
    ...Object.fromEntries(packages.map((p, i) => [`keyPackages/${target}/k${i}`, p])),
    ...(lastResort ? { [`lastResortKeyPackage/${target}`]: { keyPackage: lastResort, updatedAt: 1 } } : {}),
  });

const code = async (promise) => {
  try { await promise; } catch (e) { return e instanceof ServiceError ? e.code : `other:${e.message}`; }
  return 'ok';
};

test('window limiter', () => {
  assert.deepEqual(bumpWindow(null, 1000, 2), { start: 1000, count: 1 });
  assert.deepEqual(bumpWindow({ start: 1000, count: 1 }, 2000, 2), { start: 1000, count: 2 });
  assert.equal(bumpWindow({ start: 1000, count: 2 }, 3000, 2), null);
  assert.deepEqual(bumpWindow({ start: 1000, count: 2 }, 1000 + 3600000, 2), { start: 1000 + 3600000, count: 1 });
});

test('single-use packages are consumed one by one, in order', async () => {
  await seed('bob', ['kp1', 'kp2']);
  assert.equal(await claimKeyPackageCore(db, 'alice', 'bob'), 'kp1');
  assert.equal(await claimKeyPackageCore(db, 'alice', 'bob'), 'kp2');
  assert.equal((await db.ref('keyPackages/bob').get()).exists(), false);
});

test('concurrent claimers never get the same package', async () => {
  await seed('bob', ['kp1', 'kp2', 'kp3', 'kp4']);
  const callers = ['c1', 'c2', 'c3', 'c4'];
  const got = await Promise.all(callers.map((c) => claimKeyPackageCore(db, c, 'bob')));
  assert.equal(new Set(got).size, 4, `got ${got}`);
});

test('last resort package is served when the pool is empty, and never consumed', async () => {
  await seed('bob', [], 'LAST');
  assert.equal(await claimKeyPackageCore(db, 'alice', 'bob'), 'LAST');
  assert.equal(await claimKeyPackageCore(db, 'carol', 'bob'), 'LAST');
  assert.equal((await db.ref('lastResortKeyPackage/bob/keyPackage').get()).val(), 'LAST');
  await seed('bob', ['kp1'], 'LAST');
  assert.equal(await claimKeyPackageCore(db, 'dave', 'bob'), 'kp1', 'normal ones are preferred');
});

test('returns null when the target never published anything', async () => {
  assert.equal(await claimKeyPackageCore(db, 'alice', 'ghost'), null);
});

test('a drained pool cannot be exploited: the rate limit stops the drain', async () => {
  await seed('bob', Array.from({ length: 30 }, (_, i) => `kp${i}`), 'LAST');
  for (let i = 0; i < KP_CLAIMS_PER_HOUR; i++) await claimKeyPackageCore(db, 'mallory', 'bob');
  assert.equal(await code(claimKeyPackageCore(db, 'mallory', 'bob')), 'resource-exhausted');
  const left = (await db.ref('keyPackages/bob').get()).numChildren();
  assert.equal(left, 30 - KP_CLAIMS_PER_HOUR);
  // Someone else is not affected by mallory's limit, and a new window resets it.
  assert.equal(await code(claimKeyPackageCore(db, 'alice', 'bob')), 'ok');
  assert.equal(await code(claimKeyPackageCore(db, 'mallory', 'bob', Date.now() + 3700000)), 'ok');
});

test('blocked callers and invalid targets are refused', async () => {
  await seed('bob', ['kp1']);
  await db.ref('blocks/bob/mallory').set(true);
  assert.equal(await code(claimKeyPackageCore(db, 'mallory', 'bob')), 'permission-denied');
  assert.equal(await code(claimKeyPackageCore(db, 'alice', 'alice')), 'invalid-argument');
  assert.equal(await code(claimKeyPackageCore(db, 'alice', 'a/b')), 'invalid-argument');
  assert.equal(await code(claimKeyPackageCore(db, 'alice', '')), 'invalid-argument');
  assert.equal((await db.ref('keyPackages/bob').get()).numChildren(), 1, 'nothing consumed on refusal');
});
