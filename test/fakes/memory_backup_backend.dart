import 'dart:typed_data';

import 'package:myapp/domain/repositories/backup_backend.dart';
import 'package:myapp/domain/errors.dart';

class MemoryBackupBackend implements BackupBackend {
  final Map<String, Uint8List> shares = {};
  final Map<String, Uint8List> blobs = {};

  /// Mirrors the servers: the share is only delivered after a fresh login.
  bool recentLogin = true;
  final List<DateTime> downloads = [];
  int shareFetches = 0;

  @override
  Future<Uint8List?> getServerShare(String uid) async {
    if (!recentLogin) throw const ReauthRequiredException();
    shareFetches++;
    final share = shares[uid];
    if (share != null) downloads.add(DateTime.now());
    return share;
  }

  @override
  Future<List<DateTime>> recentShareDownloads(String uid) async => downloads.reversed.toList();

  @override
  Future<void> putServerShare(String uid, Uint8List share) async => shares[uid] = share;

  @override
  Future<BackupInfo?> getInfo(String uid) async =>
      blobs[uid] == null ? null : BackupInfo(createdAt: 0, size: blobs[uid]!.length);

  @override
  Future<Uint8List?> getBlob(String uid) async => blobs[uid];

  @override
  Future<void> putBlob(String uid, Uint8List blob) async => blobs[uid] = blob;

  @override
  Future<void> delete(String uid) async {
    blobs.remove(uid);
    shares.remove(uid);
  }
}
