import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  UserProfile _map(Map<String, dynamic> r) =>
      UserProfile(uid: r['id'] as String, nickname: r['nickname'] as String, displayName: r['display_name'] as String);

  @override
  Stream<UserProfile?> watchProfile(String uid) => _client
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', uid)
      .map((rows) => rows.isEmpty ? null : _map(rows.first));

  @override
  Future<UserProfile?> getProfile(String uid) async {
    final rows = await _client.rpc<List<dynamic>>('get_profile', params: {'p_id': uid});
    return rows.isEmpty ? null : _map((rows.first as Map).cast<String, dynamic>());
  }

  @override
  Future<void> claimNickname({required String uid, required String nickname, required String displayName}) async {
    try {
      await _client.rpc<void>('claim_nickname', params: {'p_nickname': nickname, 'p_display_name': displayName});
    } on PostgrestException catch (e) {
      if (e.message.contains('nickname_taken')) throw const NicknameTakenException();
      rethrow;
    }
  }

  @override
  Future<void> updateDisplayName({required String uid, required String displayName}) =>
      _client.from('profiles').update({'display_name': displayName}).eq('id', uid);

  @override
  Future<UserProfile?> findByNickname(String nickname) async {
    try {
      final rows = await _client.rpc<List<dynamic>>('find_profile_by_nickname', params: {'p_nickname': nickname});
      return rows.isEmpty ? null : _map((rows.first as Map).cast<String, dynamic>());
    } on PostgrestException catch (e) {
      if (e.message.contains('rate_limited')) throw const RateLimitedException();
      rethrow;
    }
  }

  @override
  Stream<Set<String>> watchBlocked(String uid) => _client
      .from('blocks')
      .stream(primaryKey: ['user_id', 'blocked_id'])
      .eq('user_id', uid)
      .map((rows) => rows.map((r) => r['blocked_id'] as String).toSet());

  @override
  Future<void> setBlocked({required String uid, required String otherUid, required bool blocked}) => blocked
      ? _client.from('blocks').upsert({'user_id': uid, 'blocked_id': otherUid})
      : _client.from('blocks').delete().eq('user_id', uid).eq('blocked_id', otherUid);

  @override
  Future<void> report({required String reporterUid, required String reportedUid, required String reason}) =>
      _client.from('reports').insert({'reported': reportedUid, 'reason': reason});
}
