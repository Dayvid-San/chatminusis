import 'dart:typed_data';

import '../errors.dart';

export '../errors.dart' show RateLimitedException, ReauthRequiredException;

/// Server side of the two-share backup (roadmap section 3.2). Stores the
/// encrypted blob and the 32-byte server share, both readable only by the
/// authenticated owner.
abstract class BackupBackend {
  /// Asks the server for the share. Only delivered right after a fresh
  /// password login (throws [ReauthRequiredException] otherwise), rate limited
  /// ([RateLimitedException]), logged and notified to the owner.
  Future<Uint8List?> getServerShare(String uid);

  /// Write-only for clients: the share can be replaced but not read back.
  Future<void> putServerShare(String uid, Uint8List share);

  /// When the share was downloaded recently (newest first), for the owner.
  Future<List<DateTime>> recentShareDownloads(String uid);

  Future<BackupInfo?> getInfo(String uid);
  Future<Uint8List?> getBlob(String uid);
  Future<void> putBlob(String uid, Uint8List blob);
  Future<void> delete(String uid);
}

class BackupInfo {
  const BackupInfo({required this.createdAt, required this.size});
  final int createdAt;
  final int size;
}
