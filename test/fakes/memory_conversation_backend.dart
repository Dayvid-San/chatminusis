import 'dart:async';
import 'dart:typed_data';

import 'package:myapp/domain/entities/conversation.dart';
import 'package:myapp/domain/repositories/conversation_backend.dart';

/// In-memory server that enforces the same invariants as the database rules:
/// epoch compare-and-set, membership checks, single-use key packages.
class MemoryConversationBackend implements ConversationBackend {
  final Map<String, Uint8List> identities = {};
  final Map<String, List<Uint8List>> keyPackages = {};
  final Map<String, ConversationRecord> conversations = {};
  final Map<String, List<Envelope>> envelopes = {};
  final Map<String, List<WelcomeEnvelope>> welcomes = {};
  final Map<String, Set<String>> blocks = {};
  int _seq = 0;

  final _envelopeCtl = StreamController<Envelope>.broadcast(sync: true);
  final _welcomeCtl = StreamController<(String, WelcomeEnvelope)>.broadcast(sync: true);
  final _changeCtl = StreamController<void>.broadcast(sync: true);

  /// When set, the next call to a write method fails once (simulated network error).
  bool failNextWrite = false;

  void _maybeFail() {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('network');
    }
  }

  @override
  String newEnvelopeId(String conversationId) => 'e${(_seq++).toString().padLeft(8, '0')}';

  @override
  Future<void> publishIdentity(String uid, Uint8List signatureKey) async => identities[uid] = signatureKey;

  @override
  Future<Uint8List?> fetchIdentity(String uid) async => identities[uid];

  @override
  Future<void> publishKeyPackages(String uid, List<Uint8List> kps) async => (keyPackages[uid] ??= []).addAll(kps);

  @override
  Future<int> countKeyPackages(String uid) async => keyPackages[uid]?.length ?? 0;

  final Map<String, Uint8List> lastResort = {};
  final Map<String, List<DateTime>> claimLog = {};
  DateTime Function() claimClock = DateTime.now;
  static const claimsPerHour = 10;

  @override
  Future<void> clearKeyPackages(String uid) async {
    keyPackages.remove(uid);
    lastResort.remove(uid);
  }

  @override
  Future<void> publishLastResortKeyPackage(String uid, Uint8List keyPackage) async => lastResort[uid] = keyPackage;

  /// Same rules as the real servers: block check, per-pair hourly limit,
  /// single-use first, last resort as reserve (never consumed).
  @override
  Future<Uint8List?> claimKeyPackage(String uid) async {
    final caller = currentCaller;
    if (blocks[uid]?.contains(caller) ?? false) throw StateError('permission-denied');
    final now = claimClock();
    final log = claimLog.putIfAbsent('$caller>$uid', () => []);
    log.removeWhere((t) => now.difference(t) >= const Duration(hours: 1));
    if (log.length >= claimsPerHour) throw const RateLimitedException();
    log.add(now);
    final list = keyPackages[uid];
    if (list != null && list.isNotEmpty) return list.removeAt(0);
    return lastResort[uid];
  }

  /// Who is calling [claimKeyPackage] (tests set it per service).
  String currentCaller = '';

  void _addEnvelope(Envelope e) {
    final stamped = Envelope(
      id: e.id,
      conversationId: e.conversationId,
      sender: e.sender,
      epoch: e.epoch,
      kind: e.kind,
      payload: e.payload,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    (envelopes[e.conversationId] ??= []).add(stamped);
    _envelopeCtl.add(stamped);
  }

  void _addWelcomes(String cid, String from, int epoch, List<WelcomeOut> ws) {
    for (final w in ws) {
      final we = WelcomeEnvelope(id: 'w${_seq++}', conversationId: cid, from: from, epoch: epoch, payload: w.payload);
      (welcomes[w.recipientUid] ??= []).add(we);
      _welcomeCtl.add((w.recipientUid, we));
    }
  }

  @override
  Future<void> createConversation({
    required ConversationRecord record,
    required Envelope firstCommit,
    required List<WelcomeOut> welcomes,
  }) async {
    _maybeFail();
    if (conversations.containsKey(record.id)) throw const EpochConflictException();
    for (final m in record.members.keys) {
      if (m != firstCommit.sender && (blocks[m]?.contains(firstCommit.sender) ?? false)) {
        throw StateError('permission-denied');
      }
    }
    conversations[record.id] = record;
    _addEnvelope(firstCommit);
    _addWelcomes(record.id, firstCommit.sender, firstCommit.epoch, welcomes);
    _changeCtl.add(null);
  }

  @override
  Future<void> publishCommit({
    required Envelope commit,
    Map<String, MemberRole?> memberChanges = const {},
    List<WelcomeOut> welcomes = const [],
  }) async {
    _maybeFail();
    final r = conversations[commit.conversationId];
    if (r == null || !r.members.containsKey(commit.sender)) throw StateError('permission-denied');
    if (!r.isAdmin(commit.sender)) throw StateError('permission-denied: only admins commit');
    if (r.epoch != commit.epoch - 1) throw const EpochConflictException();
    final members = Map.of(r.members);
    memberChanges.forEach((u, role) => role == null ? members.remove(u) : members[u] = role);
    conversations[r.id] = ConversationRecord(
      id: r.id,
      type: r.type,
      createdBy: r.createdBy,
      epoch: commit.epoch,
      members: members,
    );
    _addEnvelope(commit);
    _addWelcomes(r.id, commit.sender, commit.epoch, welcomes);
    _changeCtl.add(null);
  }

  @override
  Future<void> publishApplication(Envelope message, {required List<String> notifyUids}) async {
    _maybeFail();
    final r = conversations[message.conversationId];
    if (r == null || !r.members.containsKey(message.sender)) throw StateError('permission-denied');
    if (r.epoch != message.epoch) throw StateError('permission-denied: stale epoch');
    _addEnvelope(message);
  }

  @override
  Future<void> publishProposal(Envelope proposal) async {
    _maybeFail();
    final r = conversations[proposal.conversationId];
    if (r == null || !r.members.containsKey(proposal.sender)) throw StateError('permission-denied');
    if (r.epoch != proposal.epoch) throw StateError('permission-denied: stale epoch');
    _addEnvelope(proposal);
  }

  @override
  Future<void> leaveConversation({required String uid, required String conversationId}) async {
    final r = conversations[conversationId]!;
    conversations[conversationId] = ConversationRecord(
      id: r.id,
      type: r.type,
      createdBy: r.createdBy,
      epoch: r.epoch,
      members: Map.of(r.members)..remove(uid),
    );
    _changeCtl.add(null);
  }

  List<String> _idsFor(String uid) =>
      conversations.values.where((c) => c.members.containsKey(uid)).map((c) => c.id).toList();

  @override
  Stream<List<String>> watchConversationIds(String uid) => _replay(() => _idsFor(uid));

  @override
  Stream<ConversationRecord?> watchConversation(String id) => _replay(() => conversations[id]);

  /// Emits the current value now and again on every change.
  Stream<T> _replay<T>(T Function() read) {
    late StreamController<T> ctl;
    StreamSubscription<void>? sub;
    ctl = StreamController<T>(
      onListen: () {
        ctl.add(read());
        sub = _changeCtl.stream.listen((_) => ctl.add(read()));
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }

  @override
  Future<ConversationRecord?> getConversation(String id) async => conversations[id];

  @override
  Stream<Envelope> watchEnvelopes(String id) {
    late StreamController<Envelope> ctl;
    StreamSubscription<Envelope>? sub;
    ctl = StreamController<Envelope>(
      onListen: () {
        for (final e in List.of(envelopes[id] ?? const <Envelope>[])) {
          ctl.add(e);
        }
        sub = _envelopeCtl.stream.where((e) => e.conversationId == id).listen(ctl.add);
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }

  @override
  Stream<WelcomeEnvelope> watchWelcomes(String uid) {
    late StreamController<WelcomeEnvelope> ctl;
    StreamSubscription<WelcomeEnvelope>? sub;
    ctl = StreamController<WelcomeEnvelope>(
      onListen: () {
        for (final w in List.of(welcomes[uid] ?? const <WelcomeEnvelope>[])) {
          ctl.add(w);
        }
        sub = _welcomeCtl.stream.where((t) => t.$1 == uid).map((t) => t.$2).listen(ctl.add);
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }

  final Map<String, Set<String>> rejoin = {};

  /// Simulates server-side retention: removes envelopes matching [test].
  void pruneEnvelopes(String conversationId, bool Function(Envelope) test) =>
      envelopes[conversationId]?.removeWhere(test);

  @override
  Future<void> requestRejoin(String conversationId, String uid) async {
    if (!(conversations[conversationId]?.members.containsKey(uid) ?? false)) throw StateError('permission-denied');
    (rejoin[conversationId] ??= {}).add(uid);
    _changeCtl.add(null);
  }

  @override
  Stream<Set<String>> watchRejoinRequests(String conversationId) => _replay(() => {...?rejoin[conversationId]});

  @override
  Future<void> clearRejoin(String conversationId, String uid) async {
    rejoin[conversationId]?.remove(uid);
    _changeCtl.add(null);
  }

  @override
  Future<void> deleteWelcome(String uid, String welcomeId) async =>
      welcomes[uid]?.removeWhere((w) => w.id == welcomeId);
}
