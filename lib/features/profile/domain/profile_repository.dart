import 'package:myapp/features/profile/domain/user_profile.dart';

export 'package:myapp/core/errors.dart' show RateLimitedException;

class NicknameTakenException implements Exception {
  const NicknameTakenException();
}

abstract class ProfileRepository {
  Stream<UserProfile?> watchProfile(String uid);
  Future<UserProfile?> getProfile(String uid);

  /// Atomically reserves [nickname] for [uid] (releasing the previous one).
  /// Throws [NicknameTakenException] if someone else holds it.
  Future<void> claimNickname({required String uid, required String nickname, required String displayName});

  Future<void> updateDisplayName({required String uid, required String displayName});

  /// Exact match only: no prefix search, no suggestions. Done by the server,
  /// which rate limits it per user: throws `RateLimitedException` when exceeded.
  Future<UserProfile?> findByNickname(String nickname);

  Stream<Set<String>> watchBlocked(String uid);
  Future<void> setBlocked({required String uid, required String otherUid, required bool blocked});
  Future<void> report({required String reporterUid, required String reportedUid, required String reason});
}
