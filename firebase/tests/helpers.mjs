import { readFileSync } from 'node:fs';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { ref, get, set, update, remove, push, serverTimestamp, runTransaction } from 'firebase/database';

export { assertFails, assertSucceeds, ref, get, set, update, remove, push, serverTimestamp, runTransaction };

/** Starts a fresh environment against the running Database emulator. */
export async function setup(projectId) {
  const env = await initializeTestEnvironment({
    projectId,
    database: {
      host: '127.0.0.1',
      port: 9000,
      rules: readFileSync(new URL('../database.rules.json', import.meta.url), 'utf8'),
    },
  });
  return {
    env,
    /** Verified user database handle. */
    user: (uid, verified = true) =>
      env.authenticatedContext(uid, { email: `${uid}@test.com`, email_verified: verified }).database(),
    anon: () => env.unauthenticatedContext().database(),
    /** Seed data bypassing rules. */
    seed: (path, value) => env.withSecurityRulesDisabled((ctx) => set(ref(ctx.database(), path), value)),
  };
}
