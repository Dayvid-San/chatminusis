#!/usr/bin/env node
// Removes data the server must no longer hold, from the Realtime Database:
//   messages        the old plain-text public room
//   backups,
//   backupShares,
//   backupDownloads the server-held backups that the carrier model dropped
//
// SAFE BY DEFAULT: it only counts and reports. Nothing is deleted without
// `--confirm`, and `--confirm` first writes a local backup unless `--no-backup`.
// (A backup of a *backup* is only useful for plain-text `messages`; the others
// are encrypted blobs, but the file is written the same way.)
//
//   Dry run:  node scripts/purge-legacy-data.js --project <id>
//   Delete:   node scripts/purge-legacy-data.js --project <id> --confirm
//
// Credentials: `gcloud auth application-default login` (or GOOGLE_APPLICATION_CREDENTIALS).
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export const LEGACY_PATHS = ['messages', 'backups', 'backupShares', 'backupDownloads'];

/**
 * @param db     Admin SDK database
 * @param opts   { confirm: boolean, backupPath?: string }
 * @returns      { count, deleted, backedUpTo, perPath }  (count = total top-level entries)
 */
export async function deleteLegacyMessages(db, { confirm = false, backupPath = null } = {}) {
  const snapshots = {};
  const perPath = {};
  for (const path of LEGACY_PATHS) {
    const snap = await db.ref(path).get();
    snapshots[path] = snap.val();
    perPath[path] = snap.exists() ? snap.numChildren() : 0;
  }
  const count = Object.values(perPath).reduce((a, b) => a + b, 0);
  const result = { count, deleted: false, backedUpTo: null, perPath };
  if (!confirm || count === 0) return result;
  if (backupPath) {
    await writeFile(backupPath, JSON.stringify(snapshots, null, 2), { mode: 0o600 });
    result.backedUpTo = backupPath;
  }
  await db.ref().update(Object.fromEntries(LEGACY_PATHS.map((p) => [p, null])));
  result.deleted = true;
  return result;
}

function parseArgs(argv) {
  const args = { project: null, confirm: false, backup: true };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--project') args.project = argv[++i];
    else if (argv[i] === '--confirm') args.confirm = true;
    else if (argv[i] === '--no-backup') args.backup = false;
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.project) throw new Error('usage: --project <firebase-project-id> [--confirm] [--no-backup]');
  const { initializeApp } = await import('firebase-admin/app');
  const { getDatabase } = await import('firebase-admin/database');
  initializeApp({ projectId: args.project, databaseURL: `https://${args.project}-default-rtdb.firebaseio.com` });
  const db = getDatabase();
  const backupPath = args.confirm && args.backup ? `legacy-data-backup-${Date.now()}.json` : null;
  const result = await deleteLegacyMessages(db, { confirm: args.confirm, backupPath });
  if (!args.confirm) {
    console.log(`DRY RUN: ${JSON.stringify(result.perPath)} (top-level entries per node). Nothing was deleted. Re-run with --confirm to delete.`);
  } else if (result.deleted) {
    console.log(`Deleted ${JSON.stringify(result.perPath)}.${result.backedUpTo ? ` Backup: ${result.backedUpTo} (the old room is PLAIN TEXT: store it safely or shred it).` : ''}`);
  } else {
    console.log('Nothing to remove: the server holds none of the legacy data.');
  }
  db.goOffline();
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((e) => {
    console.error(`error: ${e.message}`);
    process.exit(1);
  });
}
