import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';

import '../repositories/backup_backend.dart';
import '../repositories/secure_store.dart';
import 'messaging_service.dart';

enum BackupError { noBackup, noServerShare, wrongCode, wrongAccount, invalidCode, reauthRequired, rateLimited }

class BackupException implements Exception {
  const BackupException(this.error);
  final BackupError error;
}

/// Encrypted backup of keys and history (roadmap 3.2): opening it needs the
/// recovery code (only the user has it) AND the server share (only delivered
/// to the authenticated owner).
class BackupService {
  BackupService({
    required BackupBackend backend,
    required SecureStore store,
    required this.uid,
    DateTime Function()? clock,
  }) : _backend = backend,
       _store = store,
       _now = clock ?? DateTime.now;

  final BackupBackend _backend;
  final SecureStore _store;
  final String uid;
  final DateTime Function() _now;

  static const _codeKey = 'backup_code';
  static const _shareKey = 'backup_share';
  static const _lastKey = 'backup_last';
  static const autoInterval = Duration(hours: 24);

  Future<bool> isEnabled() async => await _store.read(_codeKey) != null;

  Future<DateTime?> lastBackup() async {
    final v = await _store.read(_lastKey);
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(utf8.decode(v)));
  }

  Future<BackupInfo?> remoteInfo() => _backend.getInfo(uid);

  /// Turns backup on (or rotates the code). Returns the new recovery code,
  /// which must be shown to the user exactly once.
  Future<String> enable(MessagingService messaging) async {
    final code = generateRecoveryCode();
    final share = randomBytes(len: 32);
    await _backend.putServerShare(uid, share); // write-only for clients
    // This device keeps its own copy (sealed in the vault, like the code) so
    // daily backups never need the server to hand the share back.
    await _store.write(_shareKey, share);
    await _store.write(_codeKey, utf8.encode(code));
    await backupNow(messaging);
    return code;
  }

  Future<void> backupNow(MessagingService messaging) async {
    final code = await _store.read(_codeKey);
    if (code == null) return;
    final share = await _localShare();
    final entries = await messaging.exportLocalState();
    final plain = utf8.encode(
      jsonEncode({
        'v': 1,
        'uid': uid,
        'createdAt': _now().millisecondsSinceEpoch,
        'entries': {for (final e in entries.entries) e.key: base64Encode(e.value)},
      }),
    );
    final blob = await backupSeal(recoveryCode: utf8.decode(code), serverShare: share, plaintext: plain);
    await _backend.putBlob(uid, blob);
    await _store.write(_lastKey, utf8.encode('${_now().millisecondsSinceEpoch}'));
  }

  /// The share kept on this device; falls back to the server (fresh login
  /// required) for backups enabled before the local copy existed.
  Future<Uint8List> _localShare() async {
    final local = await _store.read(_shareKey);
    if (local != null) return local;
    final share = await _fetchShare();
    await _store.write(_shareKey, share);
    return share;
  }

  Future<Uint8List> _fetchShare() async {
    try {
      final share = await _backend.getServerShare(uid);
      if (share == null) throw const BackupException(BackupError.noServerShare);
      return share;
    } on ReauthRequiredException {
      throw const BackupException(BackupError.reauthRequired);
    } on RateLimitedException {
      throw const BackupException(BackupError.rateLimited);
    }
  }

  /// Recent downloads of the server share (so the owner can spot an unexpected one).
  Future<List<DateTime>> recentDownloads() => _backend.recentShareDownloads(uid);

  Future<void> maybeAutoBackup(MessagingService messaging) async {
    if (!await isEnabled()) return;
    final last = await lastBackup();
    if (last != null && _now().difference(last) < autoInterval) return;
    try {
      await backupNow(messaging);
    } catch (_) {
      // Offline: try again next time.
    }
  }

  /// Deletes the server copy and the server share (the old code stops working).
  Future<void> disable() async {
    await _backend.delete(uid);
    await _store.delete(_codeKey);
    await _store.delete(_shareKey);
    await _store.delete(_lastKey);
  }

  /// Replaces this device's (empty) store with the backup. Call before
  /// starting [MessagingService].
  Future<void> restore(String recoveryCode) async {
    if (!isValidRecoveryCode(code: recoveryCode)) throw const BackupException(BackupError.invalidCode);
    final blob = await _backend.getBlob(uid);
    if (blob == null) throw const BackupException(BackupError.noBackup);
    final share = await _fetchShare();
    final Uint8List plain;
    try {
      plain = await backupOpen(recoveryCode: recoveryCode, serverShare: share, blob: blob);
    } catch (_) {
      throw const BackupException(BackupError.wrongCode);
    }
    final json = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
    if (json['uid'] != uid) throw const BackupException(BackupError.wrongAccount);
    for (final name in await _store.names()) {
      await _store.delete(name); // keep the store's own key: only replace entries
    }
    final entries = (json['entries'] as Map).cast<String, String>();
    for (final e in entries.entries) {
      await _store.write(e.key, base64Decode(e.value));
    }
    await _store.write(MessagingService.restoredFlag, Uint8List.fromList([1]));
  }
}
