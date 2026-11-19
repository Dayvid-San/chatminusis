// Pure logic of the Cloud Functions, kept free of Firebase imports so it can
// be unit-tested with `node --test`.

/** Generic text: the server never knows (nor reveals) sender, conversation or content. */
export const GENERIC_TITLE = 'Chatminusis';
export const GENERIC_BODY = 'Nova mensagem';

/** Server-side retention of opaque messages and welcomes. */
export const RETENTION_DAYS = 30;

/**
 * Commits are tiny and let long-offline members catch up, so they are kept
 * much longer than messages (a member offline for more than this must rejoin).
 */
export const COMMIT_RETENTION_DAYS = 180;

/** Members to notify about a new envelope: everyone except the sender. */
export function recipientsFor(conversation, senderUid) {
  const members = conversation && typeof conversation.members === 'object' ? Object.keys(conversation.members) : [];
  return members.filter((uid) => uid !== senderUid);
}

/** Flattens `pushTokens/{uid}` snapshots into a list of { uid, deviceId, token }. */
export function collectTokens(tokensByUid) {
  const out = [];
  for (const [uid, devices] of Object.entries(tokensByUid ?? {})) {
    for (const [deviceId, entry] of Object.entries(devices ?? {})) {
      if (entry && typeof entry.token === 'string' && entry.token.length > 0) out.push({ uid, deviceId, token: entry.token });
    }
  }
  return out;
}

/** FCM multicast payload. Deliberately contains no data at all. */
export function buildMulticast(tokens) {
  return {
    tokens,
    notification: { title: GENERIC_TITLE, body: GENERIC_BODY },
    android: { priority: 'high', notification: { tag: 'chatminusis' } },
    apns: { headers: { 'apns-collapse-id': 'chatminusis' }, payload: { aps: { sound: 'default' } } },
  };
}

/** FCM error codes meaning the token will never work again. */
export function isDeadToken(errorCode) {
  return errorCode === 'messaging/registration-token-not-registered' || errorCode === 'messaging/invalid-registration-token';
}

/** Timestamp (ms) before which envelopes are deleted. */
export function retentionCutoff(nowMs, days = RETENTION_DAYS) {
  return nowMs - days * 24 * 60 * 60 * 1000;
}

/** Whether an MLS envelope is past its retention period. */
export function shouldPrune(envelope, nowMs) {
  if (!envelope || typeof envelope.ts !== 'number') return false;
  const days = envelope.kind === 'commit' ? COMMIT_RETENTION_DAYS : RETENTION_DAYS;
  return envelope.ts < retentionCutoff(nowMs, days);
}

/** Alert sent to the owner's devices when the backup share was downloaded. */
export const BACKUP_ALERT_BODY = 'Seu backup foi baixado. Se não foi você, troque sua senha.';

export function buildBackupAlert(tokens) {
  return {
    tokens,
    notification: { title: GENERIC_TITLE, body: BACKUP_ALERT_BODY },
    android: { priority: 'high', notification: { tag: 'chatminusis-backup' } },
    apns: { headers: { 'apns-collapse-id': 'chatminusis-backup' }, payload: { aps: { sound: 'default' } } },
  };
}
