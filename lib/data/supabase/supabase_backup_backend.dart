import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/repositories/backup_backend.dart';

class SupabaseBackupBackend implements BackupBackend {
  SupabaseBackupBackend(this._client);

  final SupabaseClient _client;

  /// `get_backup_share()`: fresh login required, logged, rate limited.
  @override
  Future<Uint8List?> getServerShare(String uid) async {
    try {
      final share = await _client.rpc<String?>('get_backup_share');
      return share == null ? null : base64Decode(share);
    } on PostgrestException catch (e) {
      if (e.message.contains('reauth_required')) throw const ReauthRequiredException();
      if (e.message.contains('rate_limited')) throw const RateLimitedException();
      rethrow;
    }
  }

  @override
  Future<void> putServerShare(String uid, Uint8List share) =>
      _client.from('backup_shares').upsert({'user_id': uid, 'share': base64Encode(share)});

  @override
  Future<List<DateTime>> recentShareDownloads(String uid) async {
    final rows = await _client
        .from('backup_downloads')
        .select('ts')
        .eq('user_id', uid)
        .order('ts', ascending: false)
        .limit(10);
    return [for (final r in rows) DateTime.parse(r['ts'] as String).toLocal()];
  }

  @override
  Future<BackupInfo?> getInfo(String uid) async {
    final row = await _client.from('backups').select('created_at, size').eq('user_id', uid).maybeSingle();
    if (row == null) return null;
    return BackupInfo(
      createdAt: DateTime.parse(row['created_at'] as String).millisecondsSinceEpoch,
      size: row['size'] as int,
    );
  }

  @override
  Future<Uint8List?> getBlob(String uid) async {
    final row = await _client.from('backups').select('blob').eq('user_id', uid).maybeSingle();
    return row == null ? null : base64Decode(row['blob'] as String);
  }

  @override
  Future<void> putBlob(String uid, Uint8List blob) => _client.from('backups').upsert({
    'user_id': uid,
    'blob': base64Encode(blob),
    'size': blob.length,
    'created_at': DateTime.now().toUtc().toIso8601String(),
  });

  @override
  Future<void> delete(String uid) async {
    await _client.from('backups').delete().eq('user_id', uid);
    await _client.from('backup_shares').delete().eq('user_id', uid);
  }
}
