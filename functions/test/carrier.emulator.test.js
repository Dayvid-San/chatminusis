import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { settleEnvelope, settleConversation } from '../core.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
const CID = 'g_group1234';
beforeEach(async () => {
  await db.ref().set(null);
  await db.ref().update({
    [`conversations/${CID}`]: { type: 'group', epoch: 1, members: { alice: 'admin', bob: 'member', carol: 'member' } },
    [`mlsMessages/${CID}/m1`]: { sender: 'alice', epoch: 1, kind: 'app', payload: 'eA==', ts: 1 },
  });
});
after(() => closeDb());

const ack = (uid, mid = 'm1') => db.ref(`acks/${CID}/${mid}/${uid}`).set(true);
const exists = async (path) => (await db.ref(path).get()).exists();

test('the envelope stays until EVERY member but the sender confirmed', async () => {
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'waiting');
  await ack('bob');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'waiting', 'carol has not received it yet');
  assert.equal(await exists(`mlsMessages/${CID}/m1`), true);
  await ack('carol');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'deleted');
});

test('once delivered, nothing is left on the server: no envelope, no confirmations', async () => {
  await ack('bob');
  await ack('carol');
  await settleEnvelope(db, CID, 'm1');
  assert.equal(await exists(`mlsMessages/${CID}/m1`), false);
  assert.equal(await exists(`acks/${CID}`), false);
});

test('the sender never has to confirm their own message', async () => {
  await ack('bob');
  await ack('carol');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'deleted');
});

test('a member who left no longer holds the message back', async () => {
  await ack('bob');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'waiting');
  await db.ref(`conversations/${CID}/members/carol`).remove();
  assert.equal(await settleConversation(db, CID), 1, 'swept after carol left');
  assert.equal(await exists(`mlsMessages/${CID}/m1`), false);
});

test('a member added later must confirm too, so they cannot be skipped', async () => {
  await ack('bob');
  await ack('carol');
  await db.ref(`conversations/${CID}/members/dave`).set('member');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'waiting', 'dave is a current member now');
  await ack('dave');
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'deleted');
});

test('confirmations of a missing envelope are cleaned up', async () => {
  await db.ref(`acks/${CID}/ghost/bob`).set(true);
  assert.equal(await settleEnvelope(db, CID, 'ghost'), 'gone');
  assert.equal(await exists(`acks/${CID}/ghost`), false);
});

test('a conversation with only the sender has nobody to wait for', async () => {
  await db.ref(`conversations/${CID}/members`).set({ alice: 'admin' });
  assert.equal(await settleEnvelope(db, CID, 'm1'), 'deleted');
});

test('only the confirmed envelope is removed; the others keep waiting', async () => {
  await db.ref(`mlsMessages/${CID}/m2`).set({ sender: 'bob', epoch: 1, kind: 'app', payload: 'eA==', ts: 2 });
  await ack('bob');
  await ack('carol');
  assert.equal(await settleConversation(db, CID), 1);
  assert.equal(await exists(`mlsMessages/${CID}/m1`), false);
  assert.equal(await exists(`mlsMessages/${CID}/m2`), true, 'm2 still waits for alice and carol');
});
