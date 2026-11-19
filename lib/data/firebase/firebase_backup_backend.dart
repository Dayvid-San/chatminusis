import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../domain/repositories/backup_backend.dart';

class FirebaseBackupBackend implements BackupBackend {
  FirebaseBackupBackend(this._db, [FirebaseFunctions? functions])
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseDatabase _db;
  final FirebaseFunctions _functions;

  /// Cloud Function `getBackupShare`: fresh login required, logged, owner alerted.
  @override
  Future<Uint8List?> getServerShare(String uid) async {
    try {
      final result = await _functions.httpsCallable('getBackupShare').call<Map<Object?, Object?>>();
      final share = result.data['share'];
      return share == null ? null : base64Decode(share as String);
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'failed-precondition') throw const ReauthRequiredException();
      if (e.code == 'resource-exhausted') throw const RateLimitedException();
      rethrow;
    }
  }

  @override
  Future<void> putServerShare(String uid, Uint8List share) =>
      _db.ref('backupShares/$uid').set({'share': base64Encode(share), 'createdAt': ServerValue.timestamp});

  @override
  Future<List<DateTime>> recentShareDownloads(String uid) async {
    final v = (await _db.ref('backupDownloads/$uid').orderByChild('at').limitToLast(10).get()).value;
    if (v is! Map) return [];
    final times = v.values.map((e) => DateTime.fromMillisecondsSinceEpoch((e as Map)['at'] as int)).toList();
    return times..sort((a, b) => b.compareTo(a));
  }

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
