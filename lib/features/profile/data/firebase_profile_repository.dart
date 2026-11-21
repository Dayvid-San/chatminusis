import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:myapp/features/profile/domain/user_profile.dart';
import 'package:myapp/features/profile/domain/profile_repository.dart';

class FirebaseProfileRepository implements ProfileRepository {
  FirebaseProfileRepository(this._db, [FirebaseFunctions? functions])
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseDatabase _db;
  final FirebaseFunctions _functions;

  DatabaseReference get _root => _db.ref();

  UserProfile? _map(String uid, Object? value) {
    if (value is! Map || value['nickname'] is! String) return null;
    return UserProfile(
      uid: uid,
      nickname: value['nickname'] as String,
      displayName: value['displayName'] as String? ?? value['nickname'] as String,
    );
  }

  @override
  Stream<UserProfile?> watchProfile(String uid) =>
      _root.child('users/$uid').onValue.map((e) => _map(uid, e.snapshot.value));

  @override
  Future<UserProfile?> getProfile(String uid) async => _map(uid, (await _root.child('users/$uid').get()).value);

  @override
  Future<void> claimNickname({required String uid, required String nickname, required String displayName}) async {
    final current = await getProfile(uid);
    if (current?.nickname == nickname) {
      await updateDisplayName(uid: uid, displayName: displayName);
      return;
    }
    final updates = <String, Object?>{
      'nicknames/$nickname': uid,
      'users/$uid/nickname': nickname,
      'users/$uid/displayName': displayName,
      if (current == null) 'users/$uid/createdAt': ServerValue.timestamp,
      if (current != null) 'nicknames/${current.nickname}': null,
    };
    try {
      await _root.update(updates);
    } on FirebaseException catch (e) {
      // The rules only reject the write when the nickname already belongs to
      // someone else (nicknames cannot be read directly any more), so ask the
      // rate-limited lookup who owns it.
      if (e.code == 'permission-denied') {
        final owner = await findByNickname(nickname);
        if (owner != null && owner.uid != uid) throw const NicknameTakenException();
      }
      rethrow;
    }
  }

  @override
  Future<void> updateDisplayName({required String uid, required String displayName}) =>
      _root.child('users/$uid/displayName').set(displayName);

  /// Server-side lookup (Cloud Function `findByNickname`): rate limited, and
  /// hides people who blocked the caller.
  @override
  Future<UserProfile?> findByNickname(String nickname) async {
    try {
      final result = await _functions.httpsCallable('findByNickname').call<Map<Object?, Object?>>({
        'nickname': nickname,
      });
      final p = result.data['profile'];
      if (p is! Map) return null;
      return UserProfile(
        uid: p['uid'] as String,
        nickname: p['nickname'] as String,
        displayName: p['displayName'] as String,
      );
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'resource-exhausted') throw const RateLimitedException();
      rethrow;
    }
  }

  @override
  Stream<Set<String>> watchBlocked(String uid) => _root.child('blocks/$uid').onValue.map((e) {
    final v = e.snapshot.value;
    return v is Map ? v.keys.cast<String>().toSet() : <String>{};
  });

  @override
  Future<void> setBlocked({required String uid, required String otherUid, required bool blocked}) =>
      _root.child('blocks/$uid/$otherUid').set(blocked ? true : null);

  @override
  Future<void> report({required String reporterUid, required String reportedUid, required String reason}) => _root
      .child('reports')
      .push()
      .set({'reporter': reporterUid, 'reported': reportedUid, 'reason': reason, 'createdAt': ServerValue.timestamp});
}
