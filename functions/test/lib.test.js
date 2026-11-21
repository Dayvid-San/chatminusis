import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildMulticast, collectTokens, isDeadToken, recipientsFor, retentionCutoff, shouldPrune, GENERIC_BODY } from '../lib.js';

test('notifies every member except the sender', () => {
  assert.deepEqual(recipientsFor({ members: { a: 'admin', b: 'member', c: 'member' } }, 'a'), ['b', 'c']);
  assert.deepEqual(recipientsFor(null, 'a'), []);
});

test('collects valid tokens only', () => {
  const tokens = collectTokens({ b: { d1: { token: 't1' }, d2: { token: '' } }, c: null, e: { d3: { token: 't3' } } });
  assert.deepEqual(tokens, [{ uid: 'b', deviceId: 'd1', token: 't1' }, { uid: 'e', deviceId: 'd3', token: 't3' }]);
});

test('push payload carries no data: generic text only', () => {
  const m = buildMulticast(['t1']);
  assert.equal(m.notification.body, GENERIC_BODY);
  assert.equal(m.data, undefined);
  const json = JSON.stringify(m);
  for (const leak of ['sender', 'cid', 'conversation', 'nickname', 'text', 'title":"G']) assert.ok(!json.includes(leak), leak);
});

test('dead tokens and retention', () => {
  assert.ok(isDeadToken('messaging/registration-token-not-registered'));
  assert.ok(!isDeadToken('messaging/internal-error'));
  assert.equal(retentionCutoff(8 * 86400000), 86400000); // 7-day retention
});

test('undelivered envelopes of every kind are dropped after 7 days', () => {
  const day = 86400000;
  const now = 400 * day;
  for (const kind of ['app', 'commit', 'proposal']) {
    assert.equal(shouldPrune({ kind, ts: now - 8 * day }, now), true, kind);
    assert.equal(shouldPrune({ kind, ts: now - 6 * day }, now), false, kind);
  }
  assert.equal(shouldPrune(null, now), false);
  assert.equal(shouldPrune({ kind: 'app' }, now), false);
});
