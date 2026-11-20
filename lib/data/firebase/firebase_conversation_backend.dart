import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_backend.dart';

/// Realtime Database transport for MLS blobs. Integrity of membership and
/// epochs is enforced by `firebase/database.rules.json`.
class FirebaseConversationBackend implements ConversationBackend {
  FirebaseConversationBackend(this._db, [FirebaseFunctions? functions])
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseDatabase _db;
  final FirebaseFunctions _functions;
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
  Future<void> clearKeyPackages(String uid) =>
      _root.update({'keyPackages/$uid': null, 'lastResortKeyPackage/$uid': null});

  @override
  Future<void> publishLastResortKeyPackage(String uid, Uint8List keyPackage) => _root
      .child('lastResortKeyPackage/$uid')
      .set({'keyPackage': _b64(keyPackage), 'updatedAt': ServerValue.timestamp});

  /// Consumption happens on the server (Cloud Function `claimKeyPackage`):
  /// clients cannot delete other people's KeyPackages.
  @override
  Future<Uint8List?> claimKeyPackage(String uid) async {
    try {
      final result = await _functions.httpsCallable('claimKeyPackage').call<Map<Object?, Object?>>({'uid': uid});
      final kp = result.data['keyPackage'];
      return kp == null ? null : _unb64(kp);
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'resource-exhausted') throw const RateLimitedException();
      rethrow;
    }
  }

  Map<String, Object?> _envelope(Envelope e) => {
    'sender': e.sender,
    'epoch': e.epoch,
    'kind': switch (e.kind) {
      EnvelopeKind.commit => 'commit',
      EnvelopeKind.proposal => 'proposal',
      EnvelopeKind.application => 'app',
    },
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
  Future<void> createConversation({required ConversationRecord record, required List<WelcomeOut> welcomes}) async {
    final u = <String, Object?>{
      'conversations/${record.id}': {
        'type': record.type.name,
        'createdBy': record.createdBy,
        'createdAt': ServerValue.timestamp,
        'epoch': 1,
        'members': {for (final m in record.members.entries) m.key: m.value.name},
      },
      for (final m in record.members.keys) 'userConversations/$m/${record.id}': {'since': ServerValue.timestamp},
    };
    _addWelcomes(u, record.id, record.createdBy, 1, welcomes);
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
  Future<void> publishApplication(Envelope message) =>
      _root.child('mlsMessages/${message.conversationId}/${message.id}').set(_envelope(message));

  /// One flag per member and envelope. A server function deletes the envelope
  /// once every current member (but the sender) has confirmed; clients can't delete.
  @override
  Future<void> ackEnvelope(Envelope envelope, String uid) =>
      _root.child('acks/${envelope.conversationId}/${envelope.id}/$uid').set(true);

  @override
  Future<void> publishProposal(Envelope proposal) =>
      _root.child('mlsMessages/${proposal.conversationId}/${proposal.id}').set(_envelope(proposal));

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
    // 'rejoin' requests live under the conversation too but are not part of the record.
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
          kind: switch (v['kind']) {
            'commit' => EnvelopeKind.commit,
            'proposal' => EnvelopeKind.proposal,
            _ => EnvelopeKind.application,
          },
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
  Future<void> requestRejoin(String conversationId, String uid) =>
      _root.child('conversations/$conversationId/rejoin/$uid').set(true);

  @override
  Stream<Set<String>> watchRejoinRequests(String conversationId) =>
      _root.child('conversations/$conversationId/rejoin').onValue.map((e) {
        final v = e.snapshot.value;
        return v is Map ? v.keys.cast<String>().toSet() : <String>{};
      });

  @override
  Future<void> clearRejoin(String conversationId, String uid) =>
      _root.child('conversations/$conversationId/rejoin/$uid').remove();

  @override
  Future<void> deleteWelcome(String uid, String welcomeId) => _root.child('welcomes/$uid/$welcomeId').remove();
}
