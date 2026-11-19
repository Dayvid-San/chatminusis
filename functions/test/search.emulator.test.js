import { test, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import { findByNicknameCore, SEARCHES_PER_HOUR, ServiceError } from '../core.js';
import { emulatorDb, closeDb } from './helpers.js';

const db = emulatorDb();
beforeEach(async () => {
  await db.ref().set(null);
  await db.ref().update({
    'nicknames/bobby': 'bob', 'users/bob': { nickname: 'bobby', displayName: 'Bob', createdAt: 1 },
    'nicknames/alice01': 'alice', 'users/alice': { nickname: 'alice01', displayName: 'Alice', createdAt: 1 },
  });
});
after(() => closeDb());

const code = async (promise) => {
  try { await promise; } catch (e) { return e instanceof ServiceError ? e.code : `other:${e.message}`; }
  return 'ok';
};

test('exact lookup returns only uid, nickname and display name', async () => {
  assert.deepEqual(await findByNicknameCore(db, 'alice', 'bobby'), { uid: 'bob', nickname: 'bobby', displayName: 'Bob' });
});

test('no prefix search, no unknown nicknames', async () => {
  assert.equal(await findByNicknameCore(db, 'alice', 'bob'), null);
  assert.equal(await findByNicknameCore(db, 'alice', 'bobbyy'), null);
});

test('yourself and people who blocked you look exactly like "not found"', async () => {
  assert.equal(await findByNicknameCore(db, 'alice', 'alice01'), null);
  await db.ref('blocks/bob/alice').set(true);
  assert.equal(await findByNicknameCore(db, 'alice', 'bobby'), null);
  assert.deepEqual(await findByNicknameCore(db, 'carol', 'bobby'), { uid: 'bob', nickname: 'bobby', displayName: 'Bob' });
});

test('malformed nicknames are rejected before touching the database', async () => {
  for (const bad of ['ab', 'a'.repeat(21), 'UPPER', 'com espaco', '.ponto', 'fim.', 'dois..pontos', '../users', '', null, 42]) {
    assert.equal(await code(findByNicknameCore(db, 'alice', bad)), 'invalid-argument', String(bad));
  }
  assert.equal((await db.ref('rateLimits').get()).exists(), false, 'invalid input is not even counted');
});

test('the limit applies to every lookup, found or not, and per user', async () => {
  for (let i = 0; i < SEARCHES_PER_HOUR; i++) await findByNicknameCore(db, 'mallory', `guess${i}x`);
  assert.equal(await code(findByNicknameCore(db, 'mallory', 'bobby')), 'resource-exhausted');
  assert.equal(await code(findByNicknameCore(db, 'alice', 'bobby')), 'ok', 'other users are unaffected');
  assert.equal(await code(findByNicknameCore(db, 'mallory', 'bobby', Date.now() + 3700000)), 'ok', 'window resets');
});
