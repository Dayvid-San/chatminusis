import 'dart:typed_data';

/// Server side of the two-share backup (roadmap section 3.2). Stores the
/// encrypted blob and the 32-byte server share, both readable only by the
/// authenticated owner.
abstract class BackupBackend {
  Future<Uint8List?> getServerShare(String uid);
  Future<void> putServerShare(String uid, Uint8List share);

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
