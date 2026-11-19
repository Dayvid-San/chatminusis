import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_backend.dart';

/// Realtime Database transport for MLS blobs. Integrity of membership and
/// epochs is enforced by `firebase/database.rules.json`.
class FirebaseConversationBackend implements ConversationBackend {
  FirebaseConversationBackend(this._db);

  final FirebaseDatabase _db;
  DatabaseReference get _root => _db.ref();

  static String _b64(Uint8List b) => base64Encode(b);
  static Uint8List _unb64(Object? s) => base64Decode(s as String);

  static bool _denied(Object e) => e is FirebaseException && e.code == 'permission-denied';

  @override
  String newEnvelopeId(String conversationId) => _root.child('mlsMessages/$conversationId').push().key!;

  @override
  Future<void> publishIdentity(String uid, Uint8List signatureKey) =>
      _root.child('identity/$uid').set({'signatureKey': _b64(signatureKey), 'updatedAt': ServerValue.timestamp});

  @override
  Future<Uint8List?> fetchIdentity(String uid) async {
    final v = (await _root.child('identity/$uid/signatureKey').get()).value;
    return v == null ? null : _unb64(v);
  }

  @override
  Future<void> publishKeyPackages(String uid, List<Uint8List> keyPackages) {
    final ref = _root.child('keyPackages/$uid');
    return ref.update({for (final kp in keyPackages) ref.push().key!: _b64(kp)});
  }

  @override
  Future<int> countKeyPackages(String uid) async {
    final v = (await _root.child('keyPackages/$uid').get()).value;
    return v is Map ? v.length : 0;
  }

  @override
  Future<void> clearKeyPackages(String uid) => _root.child('keyPackages/$uid').remove();

  @override
  Future<Uint8List?> claimKeyPackage(String uid) async {
    for (var round = 0; round < 3; round++) {
      final snap = await _root.child('keyPackages/$uid').orderByKey().limitToFirst(5).get();
      final keys = snap.children.map((c) => c.key!).toList();
      if (keys.isEmpty) return null;
      for (final key in keys) {
        Object? taken;
        final result = await _root.child('keyPackages/$uid/$key').runTransaction((current) {
          // Delete whatever is there; the server re-runs this with the real
          // value if our cached view was stale, so only one claimer wins it.
          taken = current;
          return Transaction.success(null);
        }, applyLocally: false);
        if (result.committed && taken != null) return _unb64(taken);
      }
    }
    return null;
  }

  Map<String, Object?> _envelope(Envelope e) => {
    'sender': e.sender,
    'epoch': e.epoch,
    'kind': e.kind == EnvelopeKind.commit ? 'commit' : 'app',
    'payload': _b64(e.payload),
    'ts': ServerValue.timestamp,
  };

  void _addWelcomes(Map<String, Object?> u, String cid, String from, int epoch, List<WelcomeOut> welcomes) {
    for (final w in welcomes) {
      final key = _root.child('welcomes/${w.recipientUid}').push().key!;
      u['welcomes/${w.recipientUid}/$key'] = {
        'cid': cid,
        'from': from,
        'epoch': epoch,
        'payload': _b64(w.payload),
        'ts': ServerValue.timestamp,
      };
    }
  }

  @override
  Future<void> createConversation({
    required ConversationRecord record,
    required Envelope firstCommit,
    required List<WelcomeOut> welcomes,
  }) async {
    final u = <String, Object?>{
      'conversations/${record.id}': {
        'type': record.type.name,
        'createdBy': record.createdBy,
        'createdAt': ServerValue.timestamp,
        'epoch': firstCommit.epoch,
        'members': {for (final m in record.members.entries) m.key: m.value.name},
      },
      'mlsMessages/${record.id}/${firstCommit.id}': _envelope(firstCommit),
      for (final m in record.members.keys) 'userConversations/$m/${record.id}': {'since': ServerValue.timestamp},
    };
    _addWelcomes(u, record.id, firstCommit.sender, firstCommit.epoch, welcomes);
    try {
      await _root.update(u);
    } catch (e) {
      if (_denied(e) && await _exists(record.id)) throw const EpochConflictException();
      rethrow;
    }
  }

  Future<bool> _exists(String cid) async {
    try {
      return (await _root.child('conversations/$cid/epoch').get()).exists;
    } catch (e) {
      return _denied(e); // exists but we are not a member
    }
  }

  @override
  Future<void> publishCommit({
    required Envelope commit,
    Map<String, MemberRole?> memberChanges = const {},
    List<WelcomeOut> welcomes = const [],
  }) async {
    final cid = commit.conversationId;
    final u = <String, Object?>{
      'conversations/$cid/epoch': commit.epoch,
      'mlsMessages/$cid/${commit.id}': _envelope(commit),
    };
    memberChanges.forEach((m, role) {
      u['conversations/$cid/members/$m'] = role?.name;
      u['userConversations/$m/$cid'] = role == null ? null : {'since': ServerValue.timestamp};
    });
    _addWelcomes(u, cid, commit.sender, commit.epoch, welcomes);
    try {
      await _root.update(u);
    } catch (e) {
      if (_denied(e)) {
        final epoch = (await _root.child('conversations/$cid/epoch').get()).value;
        if (epoch is int && epoch != commit.epoch - 1) throw const EpochConflictException();
      }
      rethrow;
    }
  }

  @override
  Future<void> publishApplication(Envelope message, {required List<String> notifyUids}) =>
      _root.child('mlsMessages/${message.conversationId}/${message.id}').set(_envelope(message));

  @override
  Future<void> leaveConversation({required String uid, required String conversationId}) => _root.update({
    'conversations/$conversationId/members/$uid': null,
    'userConversations/$uid/$conversationId': null,
  });

  @override
  Stream<List<String>> watchConversationIds(String uid) => _root.child('userConversations/$uid').onValue.map((e) {
    final v = e.snapshot.value;
    return v is Map ? v.keys.cast<String>().toList() : <String>[];
  });

  ConversationRecord? _record(String id, Object? v) {
    if (v is! Map) return null;
    final members = <String, MemberRole>{};
    (v['members'] as Map? ?? const {}).forEach((k, r) => members[k as String] = MemberRole.values.byName(r as String));
    return ConversationRecord(
      id: id,
      type: ConversationType.values.byName(v['type'] as String),
      createdBy: v['createdBy'] as String,
      epoch: v['epoch'] as int,
      members: members,
    );
  }

  @override
  Stream<ConversationRecord?> watchConversation(String conversationId) =>
      _root.child('conversations/$conversationId').onValue.map((e) => _record(conversationId, e.snapshot.value));

  @override
  Future<ConversationRecord?> getConversation(String conversationId) async {
    try {
      return _record(conversationId, (await _root.child('conversations/$conversationId').get()).value);
    } catch (e) {
      if (_denied(e)) return null;
      rethrow;
    }
  }

  @override
  Stream<Envelope> watchEnvelopes(String conversationId) =>
      _root.child('mlsMessages/$conversationId').orderByKey().onChildAdded.map((e) {
        final v = e.snapshot.value as Map;
        return Envelope(
          id: e.snapshot.key!,
          conversationId: conversationId,
          sender: v['sender'] as String,
          epoch: v['epoch'] as int,
          kind: v['kind'] == 'commit' ? EnvelopeKind.commit : EnvelopeKind.application,
          payload: _unb64(v['payload']),
          timestamp: v['ts'] as int? ?? 0,
        );
      });

  @override
  Stream<WelcomeEnvelope> watchWelcomes(String uid) => _root.child('welcomes/$uid').onChildAdded.map((e) {
    final v = e.snapshot.value as Map;
    return WelcomeEnvelope(
      id: e.snapshot.key!,
      conversationId: v['cid'] as String,
      from: v['from'] as String,
      epoch: v['epoch'] as int,
      payload: _unb64(v['payload']),
    );
  });

  @override
  Future<void> deleteWelcome(String uid, String welcomeId) => _root.child('welcomes/$uid/$welcomeId').remove();
}
