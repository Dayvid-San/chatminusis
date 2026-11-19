import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_database/firebase_database.dart';

import '../../domain/repositories/backup_backend.dart';

class FirebaseBackupBackend implements BackupBackend {
  FirebaseBackupBackend(this._db);

  final FirebaseDatabase _db;

  @override
  Future<Uint8List?> getServerShare(String uid) async {
    final v = (await _db.ref('backupShares/$uid/share').get()).value;
    return v == null ? null : base64Decode(v as String);
  }

  @override
  Future<void> putServerShare(String uid, Uint8List share) =>
      _db.ref('backupShares/$uid').set({'share': base64Encode(share), 'createdAt': ServerValue.timestamp});

  @override
  Future<BackupInfo?> getInfo(String uid) async {
    final v = (await _db.ref('backups/$uid/meta').get()).value;
    if (v is! Map) return null;
    return BackupInfo(createdAt: v['createdAt'] as int, size: v['size'] as int);
  }

  @override
  Future<Uint8List?> getBlob(String uid) async {
    final v = (await _db.ref('backups/$uid/blob').get()).value;
    return v == null ? null : base64Decode(v as String);
  }

  @override
  Future<void> putBlob(String uid, Uint8List blob) => _db.ref('backups/$uid').set({
    'blob': base64Encode(blob),
    'meta': {'createdAt': ServerValue.timestamp, 'size': blob.length},
  });

  @override
  Future<void> delete(String uid) => _db.ref().update({'backups/$uid': null, 'backupShares/$uid': null});
}
