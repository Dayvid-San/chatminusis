import { initializeApp } from 'firebase-admin/app';
import { getDatabase } from 'firebase-admin/database';
import { getMessaging } from 'firebase-admin/messaging';
import { onValueCreated, onValueDeleted } from 'firebase-functions/v2/database';
import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { logger } from 'firebase-functions';

import { ServiceError, claimKeyPackageCore, findByNicknameCore, requireVerified, settleConversation, settleEnvelope } from './core.js';
import { buildMulticast, collectTokens, isDeadToken, recipientsFor, retentionCutoff, shouldPrune } from './lib.js';

initializeApp();

/**
 * New MLS envelope -> content-free push to the other members.
 * Only membership is read; payloads stay opaque and are never logged.
 */
export const notifyNewEnvelope = onValueCreated({ ref: '/mlsMessages/{cid}/{mid}', region: 'us-central1' }, async (event) => {
  const db = getDatabase();
  const envelope = event.data.val();
  if (!envelope || envelope.kind !== 'app') return; // commits are silent
  const conversation = (await db.ref(`conversations/${event.params.cid}`).get()).val();
  const recipients = recipientsFor(conversation, envelope.sender);
  if (recipients.length === 0) return;

  const snaps = await Promise.all(recipients.map((uid) => db.ref(`pushTokens/${uid}`).get()));
  const tokens = collectTokens(Object.fromEntries(recipients.map((uid, i) => [uid, snaps[i].val()])));
  if (tokens.length === 0) return;

  const result = await getMessaging().sendEachForMulticast(buildMulticast(tokens.map((t) => t.token)));
  const dead = {};
  result.responses.forEach((r, i) => {
    if (!r.success && isDeadToken(r.error?.code)) dead[`pushTokens/${tokens[i].uid}/${tokens[i].deviceId}`] = null;
  });
  if (Object.keys(dead).length > 0) await db.ref().update(dead);
  logger.info('push sent', { recipients: recipients.length, devices: tokens.length, failures: result.failureCount });
});

/** Daily cleanup of old envelopes and unclaimed welcomes. */
export const pruneOldEnvelopes = onSchedule({ schedule: 'every 24 hours', region: 'us-central1' }, async () => {
  const db = getDatabase();
  const cutoff = retentionCutoff(Date.now());
  const updates = {};
  const conversations = (await db.ref('mlsMessages').get().then((s) => Object.keys(s.val() ?? {})));
  for (const cid of conversations) {
    const old = await db.ref(`mlsMessages/${cid}`).orderByChild('ts').endAt(cutoff).get();
    old.forEach((child) => {
      // Safety net: anything still undelivered after the retention period is dropped.
      if (shouldPrune(child.val(), Date.now())) {
        updates[`mlsMessages/${cid}/${child.key}`] = null;
        updates[`acks/${cid}/${child.key}`] = null;
      }
    });
  }
  const welcomes = (await db.ref('welcomes').get()).val() ?? {};
  for (const [uid, items] of Object.entries(welcomes)) {
    for (const [wid, w] of Object.entries(items ?? {})) {
      if (typeof w?.ts === 'number' && w.ts < cutoff) updates[`welcomes/${uid}/${wid}`] = null;
    }
  }
  if (Object.keys(updates).length > 0) await db.ref().update(updates);
  logger.info('pruned', { entries: Object.keys(updates).length });
});

/** Maps core errors to callable errors; anything unexpected stays opaque. */
function guard(handler) {
  return async (request) => {
    try {
      return await handler(request);
    } catch (e) {
      if (e instanceof ServiceError) throw new HttpsError(e.code, e.message);
      logger.error('callable failed', { name: e?.name });
      throw new HttpsError('internal', 'Erro interno.');
    }
  };
}

/** Atomic, rate-limited hand-over of a KeyPackage (clients cannot delete them directly). */
export const claimKeyPackage = onCall(
  { region: 'us-central1', enforceAppCheck: true },
  guard(async (request) => {
    const caller = requireVerified(request.auth);
    const keyPackage = await claimKeyPackageCore(getDatabase(), caller, request.data?.uid);
    return { keyPackage };
  }),
);

/** Rate-limited exact-nickname lookup (clients cannot read `nicknames` directly). */
export const findByNickname = onCall(
  { region: 'us-central1', enforceAppCheck: true },
  guard(async (request) => {
    const caller = requireVerified(request.auth);
    return { profile: await findByNicknameCore(getDatabase(), caller, request.data?.nickname) };
  }),
);

/** Carrier: once every member (but the sender) confirmed receipt, the envelope is deleted. */
export const onAck = onValueCreated({ ref: '/acks/{cid}/{mid}/{uid}', region: 'us-central1' }, async (event) => {
  const result = await settleEnvelope(getDatabase(), event.params.cid, event.params.mid);
  logger.info('settle', { result }); // never the ids: the server keeps no trace of who talked to whom
});

/** Someone left or was removed: envelopes that were only waiting for them can go. */
export const onMemberGone = onValueDeleted({ ref: '/conversations/{cid}/members/{uid}', region: 'us-central1' }, async (event) => {
  const deleted = await settleConversation(getDatabase(), event.params.cid);
  logger.info('swept after a member left', { deleted });
});
