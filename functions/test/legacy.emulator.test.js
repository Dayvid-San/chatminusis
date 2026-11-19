import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deleteLegacyMessages } from '../scripts/delete-legacy-messages.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
beforeEach(async () => {
  await db.ref().set(null);
  await db.ref().update({
    'messages/m1': { senderId: 'a', senderName: 'A', text: 'segredo antigo', timestamp: 1 },
    'messages/m2': { senderId: 'b', senderName: 'B', text: 'outro', timestamp: 2 },
    'users/a': { nickname: 'aaa', displayName: 'A', createdAt: 1 },
  });
});
after(() => closeDb());

test('a dry run only counts: nothing is deleted', async () => {
  assert.deepEqual(await deleteLegacyMessages(db), { count: 2, deleted: false, backedUpTo: null });
  assert.equal((await db.ref('messages').get()).numChildren(), 2);
});

test('--confirm deletes only /messages and leaves everything else alone', async () => {
  const r = await deleteLegacyMessages(db, { confirm: true });
  assert.deepEqual(r, { count: 2, deleted: true, backedUpTo: null });
  assert.equal((await db.ref('messages').get()).exists(), false);
  assert.equal((await db.ref('users/a/nickname').get()).val(), 'aaa');
});

test('a backup is written before deleting, readable only by the owner', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'legacy-'));
  try {
    const path = join(dir, 'backup.json');
    const r = await deleteLegacyMessages(db, { confirm: true, backupPath: path });
    assert.equal(r.backedUpTo, path);
    assert.equal(JSON.parse(await readFile(path, 'utf8')).m1.text, 'segredo antigo');
    const { statSync } = await import('node:fs');
    assert.equal(statSync(path).mode & 0o077, 0, 'no group/other permissions');
    assert.equal((await db.ref('messages').get()).exists(), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('an already empty room is a no-op even with --confirm', async () => {
  await db.ref('messages').set(null);
  assert.deepEqual(await deleteLegacyMessages(db, { confirm: true }), { count: 0, deleted: false, backedUpTo: null });
});
