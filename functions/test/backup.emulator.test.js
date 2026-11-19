import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { backupShareCore, BACKUP_SHARE_PER_HOUR, REAUTH_WINDOW_SECONDS, ServiceError } from '../core.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
const SHARE = 'A'.repeat(43) + '=';
beforeEach(async () => {
  await db.ref().set(null);
  await db.ref('backupShares/alice').set({ share: SHARE, createdAt: 1 });
});
after(() => closeDb());

const now = Date.now();
const sec = (ms) => Math.floor(ms / 1000);
const code = async (promise) => {
  try { await promise; } catch (e) { return e instanceof ServiceError ? `${e.code}:${e.message}` : `other:${e.message}`; }
  return 'ok';
};

test('delivers the share right after a login and logs the download', async () => {
  assert.equal(await backupShareCore(db, 'alice', sec(now) - 10, now), SHARE);
  const log = (await db.ref('backupDownloads/alice').get()).val();
  assert.deepEqual(Object.values(log), [{ at: now }]);
});

test('refuses without a recent login (stolen session, old token)', async () => {
  const stale = sec(now) - REAUTH_WINDOW_SECONDS - 5;
  assert.equal(await code(backupShareCore(db, 'alice', stale, now)), 'failed-precondition:reauth-required');
  assert.equal(await code(backupShareCore(db, 'alice', undefined, now)), 'failed-precondition:reauth-required');
  assert.equal((await db.ref('backupDownloads/alice').get()).exists(), false, 'nothing logged, nothing delivered');
});

test('there is nothing to deliver for someone without a backup, and it is not logged', async () => {
  assert.equal(await backupShareCore(db, 'bob', sec(now), now), null);
  assert.equal((await db.ref('backupDownloads/bob').get()).exists(), false);
});

test('repeated downloads hit a limit', async () => {
  for (let i = 0; i < BACKUP_SHARE_PER_HOUR; i++) await backupShareCore(db, 'alice', sec(now), now);
  assert.match(await code(backupShareCore(db, 'alice', sec(now), now)), /^resource-exhausted/);
  assert.equal(await backupShareCore(db, 'alice', sec(now) + 3700, now + 3700000), SHARE, 'new window');
});
