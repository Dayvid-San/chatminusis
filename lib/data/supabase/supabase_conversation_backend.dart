import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_backend.dart';

/// Supabase transport for MLS blobs. Integrity (membership, admin rights,
/// epoch compare-and-set, single-use key packages) is enforced by the SQL
/// functions and RLS in `supabase/migrations`.
class SupabaseConversationBackend implements ConversationBackend {
  SupabaseConversationBackend(this._client);

  final SupabaseClient _client;
  final _random = Random.secure();

  static String _b64(Uint8List b) => base64Encode(b);
  static Uint8List _unb64(Object? s) => base64Decode(s as String);

  static bool _conflict(Object e) => e is PostgrestException && e.message.contains('epoch_conflict');

  /// Time-ordered unique id (like Firebase push ids).
  @override
  String newEnvelopeId(String conversationId) {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0');
    final rand = List.generate(8, (_) => _random.nextInt(36).toRadixString(36)).join();
    return '$time$rand';
  }

  @override
  Future<void> publishIdentity(String uid, Uint8List signatureKey) => _client.from('identities').upsert({
    'user_id': uid,
    'signature_key': _b64(signatureKey),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });

  @override
  Future<Uint8List?> fetchIdentity(String uid) async {
    final row = await _client.from('identities').select('signature_key').eq('user_id', uid).maybeSingle();
    return row == null ? null : _unb64(row['signature_key']);
  }

  @override
  Future<void> publishKeyPackages(String uid, List<Uint8List> keyPackages) => _client.from('key_packages').insert([
    for (final kp in keyPackages) {'user_id': uid, 'key_package': _b64(kp)},
  ]);

  @override
  Future<int> countKeyPackages(String uid) async =>
      (await _client.from('key_packages').select('id').eq('user_id', uid)).length;

  @override
  Future<void> clearKeyPackages(String uid) async {
    await _client.from('key_packages').delete().eq('user_id', uid);
    await _client.from('last_resort_key_packages').delete().eq('user_id', uid);
  }

  @override
  Future<void> publishLastResortKeyPackage(String uid, Uint8List keyPackage) =>
      _client.from('last_resort_key_packages').upsert({
        'user_id': uid,
        'key_package': _b64(keyPackage),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

  @override
  Future<Uint8List?> claimKeyPackage(String uid) async {
    try {
      final v = await _client.rpc<String?>('claim_key_package', params: {'p_user': uid});
      return v == null ? null : _unb64(v);
    } on PostgrestException catch (e) {
      if (e.message.contains('rate_limited')) throw const RateLimitedException();
      rethrow;
    }
  }

  List<Map<String, String>> _welcomes(List<WelcomeOut> ws) => [
    for (final w in ws) {'recipient': w.recipientUid, 'payload': _b64(w.payload)},
  ];

  @override
  Future<void> createConversation({
    required ConversationRecord record,
    required Envelope firstCommit,
    required List<WelcomeOut> welcomes,
  }) async {
    try {
      await _client.rpc<void>(
        'create_conversation',
        params: {
          'p_id': record.id,
          'p_type': record.type.name,
          'p_members': {for (final m in record.members.entries) m.key: m.value.name},
          'p_commit_id': firstCommit.id,
          'p_commit': _b64(firstCommit.payload),
          'p_welcomes': _welcomes(welcomes),
        },
      );
    } catch (e) {
      if (_conflict(e)) throw const EpochConflictException();
      rethrow;
    }
  }

  @override
  Future<void> publishCommit({
    required Envelope commit,
    Map<String, MemberRole?> memberChanges = const {},
    List<WelcomeOut> welcomes = const [],
  }) async {
    try {
      await _client.rpc<void>(
        'publish_commit',
        params: {
          'p_conv': commit.conversationId,
          'p_epoch': commit.epoch,
          'p_id': commit.id,
          'p_payload': _b64(commit.payload),
          'p_member_changes': {for (final m in memberChanges.entries) m.key: m.value?.name},
          'p_welcomes': _welcomes(welcomes),
        },
      );
    } catch (e) {
      if (_conflict(e)) throw const EpochConflictException();
      rethrow;
    }
  }

  @override
  Future<void> publishApplication(Envelope message, {required List<String> notifyUids}) => _client.rpc<void>(
    'publish_application',
    params: {
      'p_conv': message.conversationId,
      'p_epoch': message.epoch,
      'p_id': message.id,
      'p_payload': _b64(message.payload),
    },
  );

  @override
  Future<void> publishProposal(Envelope proposal) => _client.rpc<void>(
    'publish_proposal',
    params: {
      'p_conv': proposal.conversationId,
      'p_epoch': proposal.epoch,
      'p_id': proposal.id,
      'p_payload': _b64(proposal.payload),
    },
  );

  @override
  Future<void> leaveConversation({required String uid, required String conversationId}) =>
      _client.from('conversation_members').delete().eq('conversation_id', conversationId).eq('user_id', uid);

  @override
  Stream<List<String>> watchConversationIds(String uid) => _client
      .from('conversation_members')
      .stream(primaryKey: ['conversation_id', 'user_id'])
      .eq('user_id', uid)
      .map((rows) => rows.map((r) => r['conversation_id'] as String).toList());

  @override
  Future<ConversationRecord?> getConversation(String conversationId) async {
    final row = await _client
        .from('conversations')
        .select('id, type, created_by, epoch, conversation_members(user_id, role)')
        .eq('id', conversationId)
        .maybeSingle();
    if (row == null) return null; // missing, or RLS: not a member
    return ConversationRecord(
      id: row['id'] as String,
      type: ConversationType.values.byName(row['type'] as String),
      createdBy: row['created_by'] as String,
      epoch: row['epoch'] as int,
      members: {
        for (final m in (row['conversation_members'] as List).cast<Map<String, dynamic>>())
          m['user_id'] as String: MemberRole.values.byName(m['role'] as String),
      },
    );
  }

  @override
  Stream<ConversationRecord?> watchConversation(String conversationId) {
    late StreamController<ConversationRecord?> ctl;
    final subs = <StreamSubscription<Object?>>[];
    Future<void> refresh() async {
      try {
        if (!ctl.isClosed) ctl.add(await getConversation(conversationId));
      } catch (e) {
        if (!ctl.isClosed) ctl.addError(e);
      }
    }

    ctl = StreamController<ConversationRecord?>(
      onListen: () {
        subs
          ..add(
            _client
                .from('conversations')
                .stream(primaryKey: ['id'])
                .eq('id', conversationId)
                .listen((_) => refresh(), onError: ctl.addError),
          )
          ..add(
            _client
                .from('conversation_members')
                .stream(primaryKey: ['conversation_id', 'user_id'])
                .eq('conversation_id', conversationId)
                .listen((_) => refresh(), onError: ctl.addError),
          );
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return ctl.stream;
  }

  /// Emits each row once, in id order, from a stream of full snapshots.
  Stream<T> _newRows<T>(
    Stream<List<Map<String, dynamic>>> snapshots,
    String Function(Map<String, dynamic>) key,
    T Function(Map<String, dynamic>) map,
  ) {
    final seen = <String>{};
    return snapshots.expand((rows) {
      final fresh = rows.where((r) => seen.add(key(r))).toList()..sort((a, b) => key(a).compareTo(key(b)));
      return fresh.map(map);
    });
  }

  @override
  Stream<Envelope> watchEnvelopes(String conversationId) => _newRows(
    _client
        .from('mls_messages')
        .stream(primaryKey: ['conversation_id', 'id'])
        .eq('conversation_id', conversationId)
        .order('id', ascending: true),
    (r) => r['id'] as String,
    (r) => Envelope(
      id: r['id'] as String,
      conversationId: conversationId,
      sender: r['sender'] as String,
      epoch: r['epoch'] as int,
      kind: switch (r['kind']) {
        'commit' => EnvelopeKind.commit,
        'proposal' => EnvelopeKind.proposal,
        _ => EnvelopeKind.application,
      },
      payload: _unb64(r['payload']),
      timestamp: DateTime.parse(r['ts'] as String).millisecondsSinceEpoch,
    ),
  );

  @override
  Stream<WelcomeEnvelope> watchWelcomes(String uid) => _newRows(
    _client.from('welcomes').stream(primaryKey: ['id']).eq('recipient', uid),
    (r) => '${r['id']}'.padLeft(20, '0'),
    (r) => WelcomeEnvelope(
      id: '${r['id']}',
      conversationId: r['conversation_id'] as String,
      from: r['sender'] as String,
      epoch: r['epoch'] as int,
      payload: _unb64(r['payload']),
    ),
  );

  @override
  Future<void> requestRejoin(String conversationId, String uid) =>
      _client.from('rejoin_requests').upsert({'conversation_id': conversationId, 'user_id': uid});

  @override
  Stream<Set<String>> watchRejoinRequests(String conversationId) => _client
      .from('rejoin_requests')
      .stream(primaryKey: ['conversation_id', 'user_id'])
      .eq('conversation_id', conversationId)
      .map((rows) => rows.map((r) => r['user_id'] as String).toSet());

  @override
  Future<void> clearRejoin(String conversationId, String uid) =>
      _client.from('rejoin_requests').delete().eq('conversation_id', conversationId).eq('user_id', uid);

  @override
  Future<void> deleteWelcome(String uid, String welcomeId) =>
      _client.from('welcomes').delete().eq('id', int.parse(welcomeId));
}
