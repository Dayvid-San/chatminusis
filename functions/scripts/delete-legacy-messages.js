#!/usr/bin/env node
// Deletes the legacy plain-text room (`/messages`) from the Realtime Database.
//
// SAFE BY DEFAULT: it only counts and reports. Nothing is deleted without
// `--confirm`, and `--confirm` first writes a local backup unless `--no-backup`.
//
//   Dry run:  node scripts/delete-legacy-messages.js --project <id>
//   Delete:   node scripts/delete-legacy-messages.js --project <id> --confirm
//
// Credentials: `gcloud auth application-default login` (or GOOGLE_APPLICATION_CREDENTIALS).
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export const LEGACY_PATH = 'messages';

/**
 * @param db     Admin SDK database
 * @param opts   { confirm: boolean, backupPath?: string }
 * @returns      { count, deleted, backedUpTo }
 */
export async function deleteLegacyMessages(db, { confirm = false, backupPath = null } = {}) {
  const snapshot = await db.ref(LEGACY_PATH).get();
  const count = snapshot.exists() ? snapshot.numChildren() : 0;
  const result = { count, deleted: false, backedUpTo: null };
  if (!confirm || count === 0) return result;
  if (backupPath) {
    await writeFile(backupPath, JSON.stringify(snapshot.val(), null, 2), { mode: 0o600 });
    result.backedUpTo = backupPath;
  }
  await db.ref(LEGACY_PATH).remove();
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
  const backupPath = args.confirm && args.backup ? `legacy-messages-backup-${Date.now()}.json` : null;
  const result = await deleteLegacyMessages(db, { confirm: args.confirm, backupPath });
  if (!args.confirm) {
    console.log(`DRY RUN: /${LEGACY_PATH} holds ${result.count} message(s). Nothing was deleted. Re-run with --confirm to delete.`);
  } else if (result.deleted) {
    console.log(`Deleted ${result.count} message(s) from /${LEGACY_PATH}.${result.backedUpTo ? ` Backup: ${result.backedUpTo} (contains plain text: store it safely or shred it).` : ''}`);
  } else {
    console.log(`/${LEGACY_PATH} is already empty. Nothing to do.`);
  }
  db.goOffline();
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((e) => {
    console.error(`error: ${e.message}`);
    process.exit(1);
  });
}
