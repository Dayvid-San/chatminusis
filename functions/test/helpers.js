import { initializeApp, getApps } from 'firebase-admin/app';
import { getDatabase } from 'firebase-admin/database';

/** Admin database wired to the Realtime Database emulator (set by `emulators:exec`). */
export function emulatorDb() {
  if (!process.env.FIREBASE_DATABASE_EMULATOR_HOST) throw new Error('run through `npm run test:emulator`');
  if (getApps().length === 0) {
    initializeApp({ projectId: 'demo-functions', databaseURL: 'https://demo-functions-default-rtdb.firebaseio.com' });
  }
  return getDatabase();
}

/** Closes the database connection so `node --test` can exit. */
export function closeDb() {
  getDatabase().goOffline();
}
