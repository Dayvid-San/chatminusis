import 'dart:async';

import 'package:myapp/domain/entities/user_profile.dart';
import 'package:myapp/domain/repositories/profile_repository.dart';

class FakeProfileRepository implements ProfileRepository {
  final Map<String, UserProfile> profiles = {};
  final Map<String, String> nicknames = {};
  final Map<String, Set<String>> blocks = {};
  final List<(String, String, String)> reports = [];
  int lookups = 0;

  /// Simulates the server refusing lookups (its own, stricter limit).
  bool serverRateLimited = false;
  final _blocksController = StreamController<void>.broadcast();

  @override
  Stream<UserProfile?> watchProfile(String uid) async* {
    yield profiles[uid];
  }

  @override
  Future<UserProfile?> getProfile(String uid) async => profiles[uid];

  @override
  Future<void> claimNickname({required String uid, required String nickname, required String displayName}) async {
    final owner = nicknames[nickname];
    if (owner != null && owner != uid) throw const NicknameTakenException();
    final old = profiles[uid];
    if (old != null) nicknames.remove(old.nickname);
    nicknames[nickname] = uid;
    profiles[uid] = UserProfile(uid: uid, nickname: nickname, displayName: displayName);
  }

  @override
  Future<void> updateDisplayName({required String uid, required String displayName}) async {
    final p = profiles[uid]!;
    profiles[uid] = UserProfile(uid: uid, nickname: p.nickname, displayName: displayName);
  }

  @override
  Future<UserProfile?> findByNickname(String nickname) async {
    if (serverRateLimited) throw const RateLimitedException();
    lookups++;
    final uid = nicknames[nickname];
    return uid == null ? null : profiles[uid];
  }

  @override
  Stream<Set<String>> watchBlocked(String uid) async* {
    yield {...?blocks[uid]};
    await for (final _ in _blocksController.stream) {
      yield {...?blocks[uid]};
    }
  }

  @override
  Future<void> setBlocked({required String uid, required String otherUid, required bool blocked}) async {
    final set = blocks.putIfAbsent(uid, () => {});
    blocked ? set.add(otherUid) : set.remove(otherUid);
    _blocksController.add(null);
  }

  @override
  Future<void> report({required String reporterUid, required String reportedUid, required String reason}) async =>
      reports.add((reporterUid, reportedUid, reason));
}
