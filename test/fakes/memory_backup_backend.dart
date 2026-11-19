import 'dart:typed_data';

import 'package:myapp/domain/repositories/backup_backend.dart';

class MemoryBackupBackend implements BackupBackend {
  final Map<String, Uint8List> shares = {};
  final Map<String, Uint8List> blobs = {};

  @override
  Future<Uint8List?> getServerShare(String uid) async => shares[uid];

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
