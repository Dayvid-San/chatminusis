import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deleteLegacyMessages as purge, LEGACY_PATHS } from '../scripts/purge-legacy-data.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
beforeEach(async () => {
  await db.ref().set(null);
  await db.ref().update({
    'messages/m1': { senderId: 'a', senderName: 'A', text: 'segredo antigo', timestamp: 1 },
    'messages/m2': { senderId: 'b', senderName: 'B', text: 'outro', timestamp: 2 },
    'backups/a': { blob: 'Q01CSw==', meta: { createdAt: 1, size: 4 } },
    'backupShares/a': { share: 'A'.repeat(43) + '=', createdAt: 1 },
    'backupDownloads/a/d1': { at: 1 },
    'users/a': { nickname: 'aaa', displayName: 'A', createdAt: 1 },
    'conversations/g_x': { type: 'group', epoch: 1 },
  });
});
after(() => closeDb());

test('the purge covers the old room and every trace of the server-held backups', () => {
  assert.deepEqual(LEGACY_PATHS, ['messages', 'backups', 'backupShares', 'backupDownloads']);
});

test('a dry run only counts: nothing is deleted', async () => {
  const r = await purge(db);
  assert.equal(r.deleted, false);
  assert.deepEqual(r.perPath, { messages: 2, backups: 1, backupShares: 1, backupDownloads: 1 });
  assert.equal(r.count, 5);
  for (const path of LEGACY_PATHS) assert.equal((await db.ref(path).get()).exists(), true, path);
});

test('--confirm deletes exactly those nodes and leaves everything else alone', async () => {
  const r = await purge(db, { confirm: true });
  assert.equal(r.deleted, true);
  for (const path of LEGACY_PATHS) assert.equal((await db.ref(path).get()).exists(), false, path);
  assert.equal((await db.ref('users/a/nickname').get()).val(), 'aaa');
  assert.equal((await db.ref('conversations/g_x/epoch').get()).val(), 1);
});

test('a backup file is written before deleting, readable only by the owner', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'purge-'));
  try {
    const path = join(dir, 'backup.json');
    const r = await purge(db, { confirm: true, backupPath: path });
    assert.equal(r.backedUpTo, path);
    assert.equal(JSON.parse(await readFile(path, 'utf8')).messages.m1.text, 'segredo antigo');
    const { statSync } = await import('node:fs');
    assert.equal(statSync(path).mode & 0o077, 0, 'no group/other permissions');
    assert.equal((await db.ref('messages').get()).exists(), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('when the server holds none of it, even --confirm is a no-op', async () => {
  await db.ref().update(Object.fromEntries(LEGACY_PATHS.map((p) => [p, null])));
  const r = await purge(db, { confirm: true });
  assert.equal(r.count, 0);
  assert.equal(r.deleted, false);
});
