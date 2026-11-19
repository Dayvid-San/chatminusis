// Server-side logic that needs the Admin SDK. Takes the database as a
// parameter so it can run against the emulator in tests (see test/*.emulator.test.js).

/** Error with a Firebase callable status code (mapped to HttpsError in index.js). */
export class ServiceError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const HOUR_MS = 60 * 60 * 1000;

/** KeyPackage claims allowed per (caller, target) per hour. */
export const KP_CLAIMS_PER_HOUR = 10;

/**
 * Fixed-window limiter, applied inside a transaction.
 * Returns the next stored value, or `null` when the limit is reached.
 */
export function bumpWindow(entry, nowMs, limit, windowMs = HOUR_MS) {
  if (!entry || typeof entry.start !== 'number' || nowMs - entry.start >= windowMs) return { start: nowMs, count: 1 };
  if (entry.count >= limit) return null;
  return { start: entry.start, count: entry.count + 1 };
}

/** Consumes one slot of the limit at `path`; throws `resource-exhausted` when full. */
export async function consumeLimit(db, path, nowMs, limit, windowMs = HOUR_MS) {
  const result = await db.ref(path).transaction((current) => bumpWindow(current, nowMs, limit, windowMs) ?? undefined);
  if (!result.committed) throw new ServiceError('resource-exhausted', 'Muitas tentativas. Tente novamente mais tarde.');
}

export function requireVerified(auth) {
  if (!auth || auth.token?.email_verified !== true) {
    throw new ServiceError('unauthenticated', 'Entre com um e-mail verificado.');
  }
  return auth.uid;
}

/**
 * Hands one KeyPackage of `targetUid` to `callerUid`.
 *
 * - Single-use packages are deleted atomically (a transaction per package).
 * - When none are left, the target's reusable last-resort package is served,
 *   so draining the pool cannot lock anyone out of being invited.
 * - Rate limited per (caller, target); refused if the target blocked the caller.
 *
 * Returns the base64 KeyPackage, or null if the target never published one.
 */
export async function claimKeyPackageCore(db, callerUid, targetUid, nowMs = Date.now()) {
  if (typeof targetUid !== 'string' || targetUid.length === 0 || targetUid.length > 128 || targetUid.includes('/')) {
    throw new ServiceError('invalid-argument', 'Usuário inválido.');
  }
  if (targetUid === callerUid) throw new ServiceError('invalid-argument', 'Não é possível convidar a si mesmo.');
  if ((await db.ref(`blocks/${targetUid}/${callerUid}`).get()).exists()) {
    throw new ServiceError('permission-denied', 'Não foi possível convidar esta pessoa.');
  }
  await consumeLimit(db, `rateLimits/kpClaim/${callerUid}/${targetUid}`, nowMs, KP_CLAIMS_PER_HOUR);

  for (let round = 0; round < 3; round++) {
    const snap = await db.ref(`keyPackages/${targetUid}`).orderByKey().limitToFirst(5).get();
    const keys = [];
    snap.forEach((child) => {
      keys.push(child.key);
    });
    if (keys.length === 0) break;
    for (const key of keys) {
      let taken = null;
      // The first call may see a stale `null`; never abort on it: returning
      // null (delete) lets the server re-run this with the real value.
      const result = await db.ref(`keyPackages/${targetUid}/${key}`).transaction((current) => {
        taken = current;
        return null;
      });
      if (result.committed && typeof taken === 'string') return taken;
    }
  }
  const lastResort = (await db.ref(`lastResortKeyPackage/${targetUid}/keyPackage`).get()).val();
  return typeof lastResort === 'string' ? lastResort : null;
}

/** Exact-nickname lookups allowed per user per hour. */
export const SEARCHES_PER_HOUR = 30;

const NICKNAME = /^[a-z0-9_.]{3,20}$/;

/**
 * Exact-nickname lookup, done by the server so the limit cannot be bypassed
 * by a modified client. Returns `{ uid, nickname, displayName }` or null.
 *
 * Not found, yourself, and "the person blocked you" all look the same (null),
 * and every call counts against the limit, so the directory cannot be mapped.
 */
export async function findByNicknameCore(db, callerUid, nickname, nowMs = Date.now()) {
  if (typeof nickname !== 'string' || !NICKNAME.test(nickname) || nickname.startsWith('.') || nickname.endsWith('.') || nickname.includes('..')) {
    throw new ServiceError('invalid-argument', 'Nickname inválido.');
  }
  await consumeLimit(db, `rateLimits/search/${callerUid}`, nowMs, SEARCHES_PER_HOUR);
  const uid = (await db.ref(`nicknames/${nickname}`).get()).val();
  if (typeof uid !== 'string' || uid === callerUid) return null;
  if ((await db.ref(`blocks/${uid}/${callerUid}`).get()).exists()) return null;
  const profile = (await db.ref(`users/${uid}`).get()).val();
  if (!profile || typeof profile.nickname !== 'string') return null;
  return { uid, nickname: profile.nickname, displayName: profile.displayName ?? profile.nickname };
}

/** The server share is only handed out right after a fresh login. */
export const REAUTH_WINDOW_SECONDS = 5 * 60;

/** Downloads of the server share allowed per user per hour. */
export const BACKUP_SHARE_PER_HOUR = 5;

/**
 * Delivers the owner's backup server share, but only if the account signed in
 * (password) within the last 5 minutes. Every delivery is logged for the owner
 * (`backupDownloads/{uid}`, timestamps only) so an unexpected one is noticed.
 *
 * `authTimeSec` is the token's `auth_time` (seconds since epoch).
 * Returns the base64 share or null if there is no backup.
 */
export async function backupShareCore(db, uid, authTimeSec, nowMs = Date.now()) {
  if (typeof authTimeSec !== 'number' || nowMs / 1000 - authTimeSec > REAUTH_WINDOW_SECONDS) {
    throw new ServiceError('failed-precondition', 'reauth-required');
  }
  await consumeLimit(db, `rateLimits/backupShare/${uid}`, nowMs, BACKUP_SHARE_PER_HOUR);
  const share = (await db.ref(`backupShares/${uid}/share`).get()).val();
  if (typeof share !== 'string') return null;
  await db.ref(`backupDownloads/${uid}`).push({ at: nowMs });
  return share;
}
