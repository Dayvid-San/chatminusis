import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';

import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/domain/conversation_backend.dart';
import 'package:myapp/features/messaging/domain/conversation_state.dart';
import 'package:myapp/features/messaging/domain/identity_pins.dart';
import 'package:myapp/features/messaging/domain/key_package_pool.dart';
import 'package:myapp/features/messaging/domain/serial_queue.dart';
import 'package:myapp/features/messaging/domain/visibility_policy.dart';
import 'package:myapp/features/security/domain/secure_store.dart';

export 'package:myapp/features/messaging/domain/identity_pins.dart' show KeyStatus;

class NoKeyPackagesException implements Exception {
  const NoKeyPackagesException(this.uids);

  /// Users that have no KeyPackage available (they need to open the app).
  final List<String> uids;
}

class NotAllowedException implements Exception {
  const NotAllowedException(this.reason);
  final String reason;
}

/// Longest visibility window a conversation may set.
const maxVisibilityWindow = Duration(days: 30);

/// Maximum members per group (decision pending with the Owner; default 256).
const maxGroupMembers = 256;

/// Rotate own keys in a conversation (self-update commit) after this long.
const _rotationInterval = Duration(days: 7);

/// End-to-end encrypted messaging on top of MLS.
///
/// Responsibilities:
/// - owns the MLS client (identity, key packages, groups) and persists it
///   sealed in the [SecureStore];
/// - turns server envelopes into decrypted messages, applying commits in
///   epoch order;
/// - publishes commits with an epoch compare-and-set, merging them only once
///   the server accepted them;
/// - keeps the decrypted history on this device only (encrypted at rest).
class MessagingService {
  MessagingService({
    required ConversationBackend backend,
    required SecureStore store,
    required this.uid,
    DateTime Function()? clock,
    this.rejoinDelay = const Duration(seconds: 10),
    this.gapDelay = const Duration(seconds: 20),
    this.repairTakeoverDelay = const Duration(seconds: 30),
  }) : _backend = backend,
       _store = store,
       _now = clock ?? DateTime.now;

  final ConversationBackend _backend;
  final SecureStore _store;
  final String uid;
  final DateTime Function() _now;

  /// How long to wait for a Welcome before asking to be re-invited.
  final Duration rejoinDelay;

  /// How long the group may stay behind the server epoch before we conclude
  /// that commits were lost (e.g. pruned after a long absence).
  final Duration gapDelay;

  /// Extra wait per rank for admins that are not the elected repairer.
  final Duration repairTakeoverDelay;

  late ChatCryptoClient _engine;
  late Uint8List _stateKey;
  late final _conversations = ConversationStore(_store);
  late final _pins = IdentityPins(_store);
  late final _keyPackages = KeyPackagePool(
    uid: uid,
    backend: _backend,
    store: _store,
    now: _now,
    generate: (count) => _lock.run(() async {
      final kps = await _engine.generateKeyPackages(count: count);
      await _persistEngine(); // private parts must be saved before publishing
      return kps;
    }),
    generateLastResort: () => _lock.run(() async {
      final kp = await _engine.generateLastResortKeyPackage();
      await _persistEngine();
      return kp;
    }),
  );
  final Map<String, List<Envelope>> _buffer = {};
  final Map<String, StreamSubscription<Envelope>> _envelopeSubs = {};
  final Map<String, StreamSubscription<ConversationRecord?>> _recordSubs = {};
  final Map<String, StreamSubscription<Set<String>>> _rejoinSubs = {};
  final Map<String, Timer> _rejoinTimers = {};
  final Map<String, Timer> _gapTimers = {};

  /// Conversations for which this device already asked to be re-invited since
  /// it last lost its keys (one request per loss).
  final Set<String> _rejoinAsked = {};
  final List<StreamSubscription<Object?>> _subs = [];
  final _changes = StreamController<void>.broadcast();
  final _lock = SerialQueue();
  bool _started = false;

  /// Set first thing in [dispose]. Work that was already in flight when the
  /// service was shut down must not start listening or confirm anything
  /// afterwards (a lingering listener would keep receiving and confirming
  /// messages for a service that can no longer store them).
  bool _disposed = false;

  Uint8List get _myId => utf8.encode(uid);

  /// Fires whenever conversations or messages change.
  Stream<void> get changes => _changes.stream;

  /// This device's public signature key (identity), as published.
  Uint8List get signaturePublicKey => _engine.signaturePublicKey;

  ChatCryptoClient get engine => _engine;

  /// Runs [job] on the serial queue without waiting. A failure (say, the disk
  /// is full) must not crash the app: nothing is confirmed to the carrier
  /// until it is stored, so the job simply runs again on the next event or
  /// when the app reopens and the envelopes are replayed.
  void _enqueue(Future<void> Function() job) {
    if (_disposed) return;
    unawaited(_lock.run(job).catchError((Object _) {}));
  }

  // ------------------------------------------------------------ lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _lock.run(() async {
      await _loadOrCreateEngine();
      await _conversations.load();
      await _pins.load();
    });
    await _keyPackages.ensure();
    _subs.add(_backend.watchWelcomes(uid).listen((w) => _enqueue(() => _onWelcome(w))));
    _subs.add(_backend.watchConversationIds(uid).listen(_onConversationIds));
    for (final c in _conversations.all.values.where((c) => !c.removed)) {
      _watch(c.id);
    }
    _emit();
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final t in [..._rejoinTimers.values, ..._gapTimers.values]) {
      t.cancel();
    }
    for (final s in [..._subs, ..._envelopeSubs.values, ..._recordSubs.values, ..._rejoinSubs.values]) {
      await s.cancel();
    }
    _subs.clear();
    _envelopeSubs.clear();
    _recordSubs.clear();
    _rejoinSubs.clear();
    // Let the job that may be running finish, so the saved state is consistent.
    await _lock.run(() async {}).catchError((Object _) {});
    await _changes.close();
  }

  Future<void> _loadOrCreateEngine() async {
    final key = await _store.read('mls_state_key');
    final state = await _store.read('mls_state');
    if (key != null && state != null) {
      _stateKey = key;
      _engine = await ChatCryptoClient.restore(state: state, key: key);
      final published = await _backend.fetchIdentity(uid);
      if (published == null || !_bytesEqual(published, _engine.signaturePublicKey)) {
        await _backend.publishIdentity(uid, _engine.signaturePublicKey);
      }
      return;
    }
    _stateKey = randomBytes(len: 32);
    await _store.write('mls_state_key', _stateKey);
    _engine = ChatCryptoClient.create(identity: _myId);
    await _persistEngine();
    await _backend.publishIdentity(uid, _engine.signaturePublicKey);
  }

  Future<void> _persistEngine() async {
    await _store.write('mls_state', await _engine.exportState(key: _stateKey));
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------ identity pins

  /// Pins every member's key on first sight and flags changes afterwards.
  Future<void> _checkKeys(ConversationState c) async {
    final gid = _gid(c.id);
    if (!_engine.hasGroup(groupId: gid)) return;
    var changed = false;
    for (final m in _engine.memberKeys(groupId: gid)) {
      final who = utf8.decode(m.identity);
      if (who == uid) continue;
      switch (_pins.observe(who, base64Encode(m.signatureKey))) {
        case PinObservation.unchanged:
          break;
        case PinObservation.pinned:
          changed = true;
        case PinObservation.changed:
          changed = true;
          for (final other in _conversations.all.values.where((x) => !x.removed && _hasMember(x, who))) {
            other.messages.add(
              DecryptedMessage(
                id: 'key-$who-${_now().millisecondsSinceEpoch}',
                conversationId: other.id,
                senderUid: '',
                text: 'A chave de segurança de um participante mudou. Confira em "Verificar segurança".',
                timestamp: _now().millisecondsSinceEpoch,
                outgoing: false,
              ),
            );
            await _conversations.save(other);
          }
      }
    }
    if (changed) await _pins.save();
  }

  bool _hasMember(ConversationState c, String who) {
    final gid = _gid(c.id);
    return _engine.hasGroup(groupId: gid) && _engine.members(groupId: gid).any((m) => utf8.decode(m) == who);
  }

  KeyStatus keyStatus(String otherUid) => _pins.statusOf(otherUid);

  /// 60-digit number both people must see identically. Uses the key currently
  /// in use (the new one, if it changed). Null if the person was never seen.
  Future<String?> safetyNumberWith(String otherUid) async {
    final key = _pins.currentKey(otherUid);
    if (key == null) return null;
    return safetyNumber(
      myIdentity: _myId,
      myKey: _engine.signaturePublicKey,
      theirIdentity: utf8.encode(otherUid),
      theirKey: base64Decode(key),
    );
  }

  /// The user compared safety numbers: trust the current key (accepting a
  /// change, if there was one).
  Future<void> markVerified(String otherUid, {bool verified = true}) async {
    if (!_pins.markVerified(otherUid, verified: verified)) return;
    await _lock.run(_pins.save);
    _emit();
  }

  // --------------------------------------------------------------- reads

  List<ConversationSummary> conversations() {
    final list = _conversations.all.values.map(_summary).toList();
    int last(ConversationSummary s) => s.lastMessage?.timestamp ?? 0;
    list.sort((a, b) => last(b).compareTo(last(a)));
    return list;
  }

  ConversationSummary? conversation(String id) {
    final c = _conversations.all[id];
    return c == null ? null : _summary(c);
  }

  /// The conversation's messages as they may be shown now: received ones whose
  /// visibility window ran out come back hidden and without their text (the
  /// text stays stored; [requestReveal] shows it again).
  List<DecryptedMessage> messages(String conversationId) {
    final c = _conversations.all[conversationId];
    if (c == null) return const [];
    return List.unmodifiable(c.messages.map(_visible(c)));
  }

  DecryptedMessage Function(DecryptedMessage) _visible(ConversationState c) {
    final nowMs = _now().millisecondsSinceEpoch;
    return (m) => VisibilityPolicy.view(c, m, nowMs);
  }

  ConversationSummary _summary(ConversationState c) {
    final has = _engine.hasGroup(groupId: _gid(c.id));
    final mls = has ? _engine.members(groupId: _gid(c.id)).map(utf8.decode).toList() : <String>[];
    final server = c.record?.members.keys.toSet();
    return ConversationSummary(
      id: c.id,
      type: c.type,
      memberUids: has ? mls : (server?.toList() ?? const []),
      isAdmin: c.record?.isAdmin(uid) ?? false,
      title: c.title,
      lastMessage: c.messages.isEmpty ? null : _visible(c)(c.messages.last),
      visibilityWindow: c.visibilitySeconds > 0 ? Duration(seconds: c.visibilitySeconds) : null,
      visibilityProposal: c.proposal,
      revealRequests: [
        for (final r in c.revealRequests)
          if (c.messages.any((m) => m.id == r.messageId && m.outgoing))
            RevealRequest(
              messageId: r.messageId,
              requester: r.requester,
              text: c.messages.firstWhere((m) => m.id == r.messageId).text,
            ),
      ],
      ended: c.removed,
      pendingWelcome: !has,
      membershipMismatch: has && server != null && !_sameSet(server, mls.toSet()),
      keyChanged: mls.any((m) => m != uid && keyStatus(m) == KeyStatus.changed),
    );
  }

  // ------------------------------------------------------- server events

  void _onConversationIds(List<String> ids) {
    for (final id in ids) {
      if (!_conversations.all.containsKey(id)) {
        final type = id.startsWith('d_') ? ConversationType.direct : ConversationType.group;
        _conversations.all[id] = ConversationState(id: id, type: type);
      }
      _watch(id);
    }
    _emit();
  }

  void _watch(String id) {
    if (_disposed) return;
    _recordSubs[id] ??= _backend
        .watchConversation(id)
        .listen((r) => _enqueue(() => _onRecord(id, r)), onError: (_) => _enqueue(() => _onRecord(id, null)));
    if (_engine.hasGroup(groupId: _gid(id))) {
      _watchEnvelopes(id);
    } else {
      // Member on the server but without keys (new phone, reinstall):
      // if no Welcome shows up, ask the others to re-invite this device.
      _scheduleRejoin(id);
    }
  }

  void _scheduleRejoin(String id) {
    if (_disposed) return;
    if (_rejoinAsked.contains(id)) return;
    _rejoinTimers[id] ??= Timer(rejoinDelay, () {
      _rejoinTimers.remove(id);
      final c = _conversations.all[id];
      if (c != null && !c.removed && !_engine.hasGroup(groupId: _gid(id)) && _rejoinAsked.add(id)) {
        unawaited(_backend.requestRejoin(id, uid).catchError((Object _) {}));
      }
    });
  }

  // ------------------------------------------------- lost-commit recovery

  bool _isBehind(ConversationState c) {
    final gid = _gid(c.id);
    final record = c.record;
    return record != null &&
        !c.removed &&
        _engine.hasGroup(groupId: gid) &&
        record.epoch > _engine.epoch(groupId: gid).toInt();
  }

  /// Called after every drain and server update: when the group stays behind
  /// the server epoch, the commits in between are gone (retention) and this
  /// device can never catch up by itself.
  void _watchGap(ConversationState c) {
    if (_disposed) return;
    if (!_isBehind(c)) {
      _gapTimers.remove(c.id)?.cancel();
      return;
    }
    _gapTimers[c.id] ??= Timer(gapDelay, () {
      _gapTimers.remove(c.id);
      _enqueue(() => _recoverFromGap(c.id));
    });
  }

  Future<void> _recoverFromGap(String id) async {
    final c = _conversations.all[id];
    if (c == null || !_isBehind(c)) return; // caught up in the meantime
    await _dropGroupAndRejoin(c, 'Você ficou muito tempo offline. Reconectando à conversa…');
  }

  /// Forgets the group state (keeping the history) and asks to be re-invited.
  Future<void> _dropGroupAndRejoin(ConversationState c, String notice) async {
    final id = c.id;
    if (_engine.hasGroup(groupId: _gid(id))) await _engine.deleteGroup(groupId: _gid(id));
    await _persistEngine();
    await _envelopeSubs.remove(id)?.cancel(); // re-subscribed (with replay) after the new Welcome
    _buffer.remove(id);
    c.messages.add(
      DecryptedMessage(
        id: 'notice-${_now().millisecondsSinceEpoch}',
        conversationId: id,
        senderUid: '',
        text: notice,
        timestamp: _now().millisecondsSinceEpoch,
        outgoing: false,
      ),
    );
    await _conversations.save(c);
    _rejoinAsked.remove(id);
    _scheduleRejoin(id);
    _emit();
  }

  void _watchEnvelopes(String id) {
    if (_disposed) return;
    _rejoinTimers.remove(id)?.cancel();
    _envelopeSubs[id] ??= _backend.watchEnvelopes(id).listen((e) {
      (_buffer[id] ??= []).add(e);
      _enqueue(() => _drain(id));
    });
    _rejoinSubs[id] ??= _backend.watchRejoinRequests(id).listen((uids) {
      for (final other in uids.where((u) => u != uid)) {
        unawaited(_repair(id, other));
      }
    });
  }

  final Set<String> _repairing = {};

  /// Re-invites [other], who lost their keys: removes their stale leaf (if
  /// any) and adds their new device from a fresh KeyPackage. Direct chats:
  /// either member may do it; groups: admins only.
  Future<void> _repair(String id, String other) async {
    final key = '$id/$other';
    if (!_repairing.add(key)) return;
    try {
      final c = _conversations.all[id];
      final record = c?.record ?? await _backend.getConversation(id);
      if (c == null || record == null || !record.members.containsKey(other)) return;
      // Elected repairer: the lowest uid among the admins other than the
      // requester. Others only step in, in rank order, if the request is
      // still open after their extra wait (prevents double repairs).
      final admins =
          record.members.entries.where((e) => e.value == MemberRole.admin && e.key != other).map((e) => e.key).toList()
            ..sort();
      final rank = admins.indexOf(uid);
      if (rank < 0) return;
      if (rank > 0) await Future<void>.delayed(repairTakeoverDelay * rank);
      // Never act on a stale request: it must still be open right now.
      if (!(await _backend.watchRejoinRequests(id).first).contains(other)) return;
      final gid = _gid(id);
      final current = _engine.memberKeys(groupId: gid).where((m) => utf8.decode(m.identity) == other).toList();
      if (current.isNotEmpty) {
        await _withCommitRetry(id, () async {
          if (!_engine.members(groupId: gid).any((m) => utf8.decode(m) == other)) return;
          final out = await _engine.removeMembers(groupId: gid, identities: [utf8.encode(other)]);
          await _publishCommit(id, out);
        });
      }
      final kp = await _backend.claimKeyPackage(other);
      if (kp == null) return; // they have not published keys yet; request stays open
      await _withCommitRetry(id, () async {
        final out = await _engine.addMembers(groupId: gid, keyPackages: [kp]);
        await _publishCommit(
          id,
          out,
          welcomes: [WelcomeOut(recipientUid: other, payload: out.welcome!)],
        );
      });
      await _backend.clearRejoin(id, other);
      await _sendPayload(id, {'t': 'meta', if (c.title != null) 'title': c.title, 'vs': c.visibilitySeconds});
      _emit();
    } catch (_) {
      // Lost a race or offline: the request stays and is retried on the next change.
    } finally {
      _repairing.remove(key);
    }
  }

  Future<void> _onRecord(String id, ConversationRecord? record) async {
    final c = _conversations.all[id];
    if (c == null) return;
    if (record == null || !record.members.containsKey(uid)) {
      // We were removed (or left): forget the keys, keep the local history.
      await _envelopeSubs.remove(id)?.cancel();
      await _recordSubs.remove(id)?.cancel();
      await _rejoinSubs.remove(id)?.cancel();
      _rejoinTimers.remove(id)?.cancel();
      _gapTimers.remove(id)?.cancel();
      if (_engine.hasGroup(groupId: _gid(id))) {
        await _engine.deleteGroup(groupId: _gid(id));
        await _persistEngine();
      }
      c.removed = true;
      c.record = record;
      await _conversations.save(c);
      _emit();
      return;
    }
    c.record = record;
    await _conversations.save(c);
    _watchGap(c);
    await _reconcile(c);
    _emit();
  }

  /// Admins remove from the MLS group anyone the server no longer lists
  /// (e.g. members who left), so they stop receiving keys.
  Future<void> _reconcile(ConversationState c) async {
    final record = c.record;
    final gid = _gid(c.id);
    if (record == null || !record.isAdmin(uid) || !_engine.hasGroup(groupId: gid)) return;
    if (record.epoch != _engine.epoch(groupId: gid).toInt()) return; // catch up first
    final extras = _engine.members(groupId: gid).map(utf8.decode).where((m) => !record.members.containsKey(m)).toList();
    if (extras.isEmpty) return;
    try {
      final out = await _engine.removeMembers(groupId: gid, identities: extras.map(utf8.encode).toList());
      await _publishCommit(c.id, out);
    } on EpochConflictException {
      // Another admin did it first; the winning commit will arrive.
    }
  }

  Future<void> _onWelcome(WelcomeEnvelope w) async {
    final record = await _backend.getConversation(w.conversationId);
    final invited = record != null && record.members.containsKey(uid) && record.members.containsKey(w.from);
    if (!invited || _engine.hasGroup(groupId: _gid(w.conversationId))) {
      await _backend.deleteWelcome(uid, w.id);
      return;
    }
    try {
      final gid = await _engine.joinGroup(welcome: w.payload);
      if (utf8.decode(gid) != w.conversationId) {
        // Welcome for a different group than claimed: drop it.
        await _engine.deleteGroup(groupId: gid);
        throw const FormatException('group id mismatch');
      }
      await _persistEngine();
      final c = _conversations.all[w.conversationId] ?? ConversationState(id: w.conversationId, type: record.type);
      c
        ..type = record.type
        ..record = record
        ..removed = false
        ..joinedEpoch = _engine.epoch(groupId: gid).toInt()
        ..lastRotation = _now().millisecondsSinceEpoch
        ..awaitingVisibilityState = _engine.epoch(groupId: gid).toInt() > 1;
      await _conversations.save(c);
      await _checkKeys(c);
      _rejoinTimers.remove(c.id)?.cancel();
      if (_rejoinAsked.remove(c.id)) {
        await _backend.clearRejoin(c.id, uid).catchError((Object _) {});
      }
      _watchEnvelopes(c.id);
    } catch (_) {
      // Invalid or stale welcome (e.g. key package already used): ignore.
    }
    await _backend.deleteWelcome(uid, w.id);
    _emit();
  }

  /// Applies buffered envelopes in (epoch, id) order as far as possible.
  Future<void> _drain(String id) async {
    final c = _conversations.all[id];
    final queue = _buffer[id];
    final gid = _gid(id);
    if (c == null || !_engine.hasGroup(groupId: gid)) return;
    if (queue == null || queue.isEmpty) {
      _watchGap(c);
      return;
    }
    queue.sort((a, b) => a.epoch != b.epoch ? a.epoch.compareTo(b.epoch) : a.id.compareTo(b.id));
    var changed = false;
    final toAck = <Envelope>[]; // delivered: confirmed to the carrier once safely stored
    while (queue.isNotEmpty && _engine.hasGroup(groupId: gid)) {
      final e = queue.first;
      final local = _engine.epoch(groupId: gid).toInt();
      if (c.processed.contains(e.id)) {
        toAck.add(e); // seen before (e.g. the confirmation was lost): confirm again
        queue.removeAt(0);
        continue;
      }
      if (e.kind == EnvelopeKind.commit) {
        if (e.epoch <= local) {
          _markProcessed(c, e.id); // already applied (ours, or before we joined)
        } else if (e.epoch == local + 1) {
          if (e.sender == uid) {
            // Our commit was accepted but the app stopped before merging it.
            try {
              await _engine.mergePendingCommit(groupId: gid);
            } catch (_) {}
          } else {
            try {
              final r = await _engine.process(groupId: gid, message: e.payload, expected: ExpectedContent.commit);
              if (r.kind == IncomingKind.commit && !r.stillMember) {
                await _engine.deleteGroup(groupId: gid);
                c.removed = true;
              }
            } catch (_) {
              _addSystem(c, e, 'Não foi possível aplicar uma atualização de chaves.');
            }
          }
          _markProcessed(c, e.id);
        } else {
          break; // a commit in between is still missing
        }
      } else if (e.kind == EnvelopeKind.proposal) {
        if (e.epoch > local) break; // wait for the commit that opens this epoch
        // A member's own key-rotation request (already stored locally if it is
        // ours). Only self updates are kept; anything else is dropped. Content
        // that is not a proposal at all is refused by the core.
        if (e.sender != uid && e.epoch == local) {
          try {
            await _engine.process(groupId: gid, message: e.payload, expected: ExpectedContent.proposal);
          } catch (_) {
            _addSystem(c, e, 'Uma solicitação inválida foi ignorada.');
          }
        }
        _markProcessed(c, e.id);
      } else {
        if (e.epoch > local) break; // wait for the commit that opens this epoch
        if (e.sender != uid && e.epoch >= c.joinedEpoch) {
          try {
            // A commit disguised as a message is refused here, before anything is applied.
            final r = await _engine.process(groupId: gid, message: e.payload, expected: ExpectedContent.application);
            if (r.kind == IncomingKind.application) {
              _handlePayload(c, e, utf8.decode(r.sender), r.plaintext);
            }
          } catch (_) {
            _addSystem(c, e, 'Mensagem que não pôde ser decifrada.');
          }
        }
        _markProcessed(c, e.id);
      }
      toAck.add(e);
      queue.removeAt(0);
      changed = true;
    }
    if (!changed) {
      _confirmDelivery(toAck); // already stored on an earlier run
      _watchGap(c);
      return;
    }
    _reconcileProposal(c);
    await _persistEngine();
    await _conversations.save(c);
    // Only now is the message really ours: the server may forget it.
    _confirmDelivery(toAck);
    _watchGap(c);
    if (!c.removed) {
      await _checkKeys(c);
      await _reconcile(c);
      await _commitPendingProposals(c);
      await _rotateIfStale(c);
    }
    _emit();
  }

  /// Whether this device may publish commits in [c]: admins, and both people
  /// of a direct chat. (The server enforces the same rule.)
  bool _canCommit(ConversationState c) => c.record?.isAdmin(uid) ?? false;

  /// Admins turn members' stored key-rotation proposals into one commit.
  Future<void> _commitPendingProposals(ConversationState c) async {
    final gid = _gid(c.id);
    final record = c.record;
    if (!_canCommit(c) || record == null || !_engine.hasGroup(groupId: gid)) return;
    if (record.epoch != _engine.epoch(groupId: gid).toInt()) return; // catch up first
    if (!_engine.hasPendingProposals(groupId: gid)) return;
    try {
      final out = await _engine.commitPendingProposals(groupId: gid);
      await _publishCommit(c.id, out);
    } catch (_) {
      // Another admin committed first (the winner's commit covers the same
      // proposals) or we are offline: retried on the next activity.
    }
  }

  /// Tells the carrier we have these envelopes. Best effort: if it fails, the
  /// envelope is still on the server and is confirmed again on the next replay.
  void _confirmDelivery(List<Envelope> delivered) {
    if (_disposed) return; // shut down mid-way: leave it on the server rather than risk losing it
    for (final e in delivered) {
      if (e.sender == uid) continue; // our own message: nothing to confirm
      unawaited(_backend.ackEnvelope(e, uid).catchError((Object _) {}));
    }
  }

  void _markProcessed(ConversationState c, String id) {
    c.processed.add(id);
    if (c.processed.length > 5000) c.processed.remove(c.processed.first);
  }

  void _handlePayload(ConversationState c, Envelope e, String sender, Uint8List plaintext) {
    if (sender != e.sender) return; // server-claimed sender must match the MLS signature
    final Map<String, Object?> p;
    try {
      p = jsonDecode(utf8.decode(plaintext)) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    switch (p['t']) {
      case 'msg':
        final text = p['text'];
        if (text is! String || text.isEmpty) return;
        final received = _now().millisecondsSinceEpoch;
        c.messages.add(
          DecryptedMessage(
            id: e.id,
            conversationId: c.id,
            senderUid: sender,
            text: text,
            timestamp: e.timestamp == 0 ? received : e.timestamp,
            outgoing: false,
          ),
        );
      case 'meta':
        // Only admins may rename a group.
        final title = p['title'];
        final isAdmin = c.record?.isAdmin(sender) ?? false;
        if (c.type == ConversationType.group && title is String && isAdmin) {
          c.title = title.length > 60 ? title.substring(0, 60) : title;
        }
        // What was agreed, told to someone who joined later. Only an admin may
        // say it and only to a device that is still waiting for it: it can never
        // change a window the current members already have.
        final vs = p['vs'];
        if (vs is int && vs >= 0 && vs <= maxVisibilityWindow.inSeconds && c.awaitingVisibilityState && isAdmin) {
          VisibilityPolicy.apply(c, vs, _now().millisecondsSinceEpoch);
          c.awaitingVisibilityState = false;
        }
      case 'vp': // a member proposes a window
        final pid = p['pid'];
        final seconds = p['s'];
        final members = _memberSet(c);
        if (pid is String && seconds is int && seconds >= 0 && seconds <= maxVisibilityWindow.inSeconds) {
          if (members.contains(sender)) {
            c.proposal = VisibilityProposal(
              id: pid,
              seconds: seconds,
              proposer: sender,
              acks: {sender},
              members: members,
            );
            _reconcileProposal(c);
          }
        }
      case 'va': // a member accepts it
        final proposal = c.proposal;
        if (proposal != null && p['pid'] == proposal.id && proposal.members.contains(sender)) {
          c.proposal = proposal.withAck(sender);
          _reconcileProposal(c);
        }
      case 'vn': // a member refuses it (or the proposer withdraws it): the window stays
        final proposal = c.proposal;
        if (proposal != null && p['pid'] == proposal.id && proposal.members.contains(sender)) c.proposal = null;
      case 'rq': // someone asks to see a message of mine again
        final mid = p['m'];
        final mine = mid is String && c.messages.any((m) => m.id == mid && m.outgoing);
        if (mine && !c.revealRequests.any((r) => r.messageId == mid && r.requester == sender)) {
          c.revealRequests.add(RevealRequest(messageId: mid, requester: sender));
        }
      case 'rs': // the sender answered my request
        final mid = p['m'];
        final i = c.messages.indexWhere((m) => m.id == mid);
        if (i >= 0 && p['to'] == uid && p['ok'] is bool) {
          final m = c.messages[i];
          if (!m.outgoing && m.senderUid == sender && m.reveal == 'req') {
            if (p['ok'] == true) {
              VisibilityPolicy.reveal(c, m.id, _now().millisecondsSinceEpoch);
            } else {
              c.messages[i] = m.copyWith(reveal: 'den');
            }
          }
        }
    }
  }

  void _addSystem(ConversationState c, Envelope e, String text) {
    c.messages.add(
      DecryptedMessage(
        id: e.id,
        conversationId: c.id,
        senderUid: '',
        text: text,
        timestamp: e.timestamp == 0 ? _now().millisecondsSinceEpoch : e.timestamp,
        outgoing: false,
      ),
    );
  }

  // --------------------------------------------------------------- writes

  /// Starts (or returns) the 1:1 conversation with [otherUid].
  Future<String> startDirect(String otherUid) async {
    if (otherUid == uid) throw const NotAllowedException('Não é possível conversar consigo.');
    final ids = [uid, otherUid]..sort();
    final id = 'd_${ids[0]}_${ids[1]}';
    return _lock.run(() async {
      if (_engine.hasGroup(groupId: _gid(id))) return id;
      ConversationRecord? existing;
      try {
        existing = await _backend.getConversation(id);
      } catch (_) {
        existing = null;
      }
      if (existing != null) {
        _conversations.all.putIfAbsent(id, () => ConversationState(id: id, type: ConversationType.direct));
        _watch(id);
        return id; // created by the other side: waiting for its Welcome
      }
      final kp = await _backend.claimKeyPackage(otherUid);
      if (kp == null) throw NoKeyPackagesException([otherUid]);
      final record = ConversationRecord(
        id: id,
        type: ConversationType.direct,
        createdBy: uid,
        epoch: 1,
        members: {uid: MemberRole.admin, otherUid: MemberRole.admin},
      );
      await _create(record, [kp], [otherUid]);
      return id;
    });
  }

  /// Creates a group with [title] and the given members.
  Future<String> createGroup(String title, List<String> memberUids) async {
    final others = memberUids.where((m) => m != uid).toSet().toList();
    if (others.isEmpty) throw const NotAllowedException('Escolha pelo menos uma pessoa.');
    if (others.length + 1 > maxGroupMembers) throw const NotAllowedException('Grupo muito grande.');
    final id = 'g_${_hex(randomBytes(len: 16))}';
    await _lock.run(() async {
      final kps = <Uint8List>[];
      final missing = <String>[];
      for (final m in others) {
        final kp = await _backend.claimKeyPackage(m);
        kp == null ? missing.add(m) : kps.add(kp);
      }
      if (missing.isNotEmpty) throw NoKeyPackagesException(missing);
      final record = ConversationRecord(
        id: id,
        type: ConversationType.group,
        createdBy: uid,
        epoch: 1,
        members: {uid: MemberRole.admin, for (final m in others) m: MemberRole.member},
      );
      await _create(record, kps, others);
      _conversations.all[id]!.title = title.trim();
      await _conversations.save(_conversations.all[id]!);
    });
    await _sendPayload(id, {'t': 'meta', 'title': title.trim()});
    return id;
  }

  Future<void> _create(ConversationRecord record, List<Uint8List> kps, List<String> invitees) async {
    final gid = _gid(record.id);
    await _engine.createGroup(groupId: gid);
    try {
      final out = await _engine.addMembers(groupId: gid, keyPackages: kps);
      await _backend.createConversation(
        record: record,
        welcomes: [for (final u in invitees) WelcomeOut(recipientUid: u, payload: out.welcome!)],
      );
      await _engine.mergePendingCommit(groupId: gid);
    } catch (_) {
      await _engine.deleteGroup(groupId: gid);
      rethrow;
    }
    final c = ConversationState(id: record.id, type: record.type)
      ..record = record
      ..joinedEpoch = 1
      ..lastRotation = _now().millisecondsSinceEpoch;
    await _persistEngine();
    await _conversations.save(c);
    await _checkKeys(c);
    _watch(record.id);
    _emit();
  }

  Envelope _commitEnvelope(String id, CommitResult out) => Envelope(
    id: _backend.newEnvelopeId(id),
    conversationId: id,
    sender: uid,
    epoch: out.newEpoch.toInt(),
    kind: EnvelopeKind.commit,
    payload: out.commit,
  );

  /// Publishes a pending commit; merges it on success, clears it on conflict.
  Future<void> _publishCommit(
    String id,
    CommitResult out, {
    Map<String, MemberRole?> memberChanges = const {},
    List<WelcomeOut> welcomes = const [],
  }) async {
    final gid = _gid(id);
    final env = _commitEnvelope(id, out);
    try {
      await _backend.publishCommit(commit: env, memberChanges: memberChanges, welcomes: welcomes);
    } on EpochConflictException {
      await _engine.clearPendingCommit(groupId: gid);
      await _persistEngine();
      rethrow;
    } catch (_) {
      await _engine.clearPendingCommit(groupId: gid);
      await _persistEngine();
      rethrow;
    }
    await _engine.mergePendingCommit(groupId: gid);
    final c = _conversations.all[id]!;
    _markProcessed(c, env.id);
    _reconcileProposal(c); // the members may have changed under a pending proposal
    await _persistEngine();
    await _conversations.save(c);
    await _checkKeys(c);
  }

  /// Runs [build] + publish, retrying after catching up when another member
  /// committed first.
  Future<void> _withCommitRetry(String id, Future<void> Function() attempt) async {
    for (var i = 0; ; i++) {
      try {
        await _lock.run(attempt);
        return;
      } on EpochConflictException {
        if (i >= 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
        await _lock.run(() => _drain(id));
      }
    }
  }

  Future<void> addMember(String id, String otherUid) async {
    final c = _requireAdminGroup(id);
    if ((c.record?.members.length ?? 0) + 1 > maxGroupMembers) throw const NotAllowedException('Grupo cheio.');
    if (c.record?.members.containsKey(otherUid) ?? false) return;
    final kp = await _backend.claimKeyPackage(otherUid);
    if (kp == null) throw NoKeyPackagesException([otherUid]);
    await _withCommitRetry(id, () async {
      final out = await _engine.addMembers(groupId: _gid(id), keyPackages: [kp]);
      await _publishCommit(
        id,
        out,
        memberChanges: {otherUid: MemberRole.member},
        welcomes: [WelcomeOut(recipientUid: otherUid, payload: out.welcome!)],
      );
    });
    // Newcomers cannot read older messages: re-send the encrypted title.
    await _sendPayload(id, {'t': 'meta', if (c.title != null) 'title': c.title, 'vs': c.visibilitySeconds});
    _emit();
  }

  Future<void> removeMember(String id, String otherUid) async {
    _requireAdminGroup(id);
    await _withCommitRetry(id, () async {
      final out = await _engine.removeMembers(groupId: _gid(id), identities: [utf8.encode(otherUid)]);
      await _publishCommit(id, out, memberChanges: {otherUid: null});
    });
    _emit();
  }

  Future<void> rename(String id, String title) async {
    final c = _requireAdminGroup(id);
    c.title = title.trim();
    await _lock.run(() => _conversations.save(c));
    await _sendPayload(id, {'t': 'meta', 'title': title.trim()});
  }

  /// Rotates this member's keys in the conversation (post-compromise security).
  /// Admins commit directly; ordinary members send a proposal that an admin
  /// commits (the server does not let them commit).
  Future<void> rotateKeys(String id) async {
    final c = _conversations.all[id];
    if (c != null && c.record != null && !_canCommit(c)) {
      await _lock.run(() => _proposeRotation(c));
      return;
    }
    await _withCommitRetry(id, () async {
      final out = await _engine.selfUpdate(groupId: _gid(id));
      await _publishCommit(id, out);
      _conversations.all[id]!.lastRotation = _now().millisecondsSinceEpoch;
      await _conversations.save(_conversations.all[id]!);
    });
  }

  Future<void> _proposeRotation(ConversationState c) async {
    final gid = _gid(c.id);
    if (!_engine.hasGroup(groupId: gid)) return;
    final proposal = await _engine.proposeSelfUpdate(groupId: gid);
    final env = Envelope(
      id: _backend.newEnvelopeId(c.id),
      conversationId: c.id,
      sender: uid,
      epoch: _engine.epoch(groupId: gid).toInt(),
      kind: EnvelopeKind.proposal,
      payload: proposal,
    );
    await _backend.publishProposal(env);
    _markProcessed(c, env.id);
    c.lastRotation = _now().millisecondsSinceEpoch;
    await _persistEngine();
    await _conversations.save(c);
  }

  Future<void> _rotateIfStale(ConversationState c) async {
    final age = _now().millisecondsSinceEpoch - c.lastRotation;
    if (age < _rotationInterval.inMilliseconds || c.record == null) return;
    try {
      if (_canCommit(c)) {
        final out = await _engine.selfUpdate(groupId: _gid(c.id));
        await _publishCommit(c.id, out);
        c.lastRotation = _now().millisecondsSinceEpoch;
        await _conversations.save(c);
      } else {
        await _proposeRotation(c);
      }
    } catch (_) {
      // Lost a race or offline: try again on the next activity.
    }
  }

  Future<void> leave(String id) async {
    await _backend.leaveConversation(uid: uid, conversationId: id);
    await _lock.run(() => _onRecord(id, null));
  }

  ConversationState _requireAdminGroup(String id) {
    final c = _conversations.all[id];
    if (c == null || c.type != ConversationType.group) throw const NotAllowedException('Conversa inválida.');
    if (!(c.record?.isAdmin(uid) ?? false)) throw const NotAllowedException('Apenas administradores.');
    return c;
  }

  /// Sends a text message.
  Future<void> send(String id, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > 4000) throw const NotAllowedException('Mensagem muito longa.');
    await _sendPayload(id, {'t': 'msg', 'text': trimmed}, localText: trimmed);
  }

  /// Lets a test send a payload the public API would refuse, to check that
  /// receivers enforce the rules themselves.
  Future<void> sendPayloadForTest(String id, Map<String, Object?> payload) => _sendPayload(id, payload);

  Future<void> _sendPayload(
    String id,
    Map<String, Object?> payload, {
    String? localText,
    void Function(ConversationState c)? onPublished,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _lock.run(() async {
          final c = _conversations.all[id];
          final gid = _gid(id);
          if (c == null || c.removed || !_engine.hasGroup(groupId: gid)) {
            throw const NotAllowedException('Conversa indisponível.');
          }
          final body = utf8.encode(jsonEncode({'v': 1, ...payload}));
          final ct = await _engine.encrypt(groupId: gid, plaintext: body);
          final env = Envelope(
            id: _backend.newEnvelopeId(id),
            conversationId: id,
            sender: uid,
            epoch: _engine.epoch(groupId: gid).toInt(),
            kind: EnvelopeKind.application,
            payload: ct,
          );
          await _backend.publishApplication(env);
          _markProcessed(c, env.id);
          onPublished?.call(c);
          if (localText != null) {
            final now = _now().millisecondsSinceEpoch;
            c.messages.add(
              DecryptedMessage(
                id: env.id,
                conversationId: id,
                senderUid: uid,
                text: localText,
                timestamp: now,
                outgoing: true,
              ),
            );
          }
          await _persistEngine();
          await _conversations.save(c);
        });
        _emit();
        return;
      } on NotAllowedException {
        rethrow;
      } catch (_) {
        // Usually the epoch moved on under us: catch up and re-encrypt.
        if (attempt >= 2) rethrow;
        await _lock.run(() => _drain(id));
      }
    }
  }

  /// Deletes one message from this device. There is no copy anywhere else: the
  /// server keeps nothing and the other person's copy is theirs to keep or lose.
  Future<void> deleteMessage(String conversationId, String messageId) => _lock.run(() async {
    final c = _conversations.all[conversationId];
    if (c == null) return;
    final before = c.messages.length;
    c.messages.removeWhere((m) => m.id == messageId);
    if (c.messages.length != before) await _conversations.save(c);
    _emit();
  });

  /// Deletes this conversation's whole history from this device (the group and
  /// its keys stay, so it keeps working for new messages).
  Future<void> clearHistory(String conversationId) => _lock.run(() async {
    final c = _conversations.all[conversationId];
    if (c == null) return;
    c.messages.clear();
    await _conversations.save(c);
    _emit();
  });

  // ------------------------------------------------------ visibility

  Set<String> _memberSet(ConversationState c) {
    final gid = _gid(c.id);
    return _engine.hasGroup(groupId: gid) ? _engine.members(groupId: gid).map(utf8.decode).toSet() : <String>{};
  }

  /// Applies the proposal once every current member accepted it; drops it if
  /// the members are no longer the ones it was proposed to.
  void _reconcileProposal(ConversationState c) {
    final p = c.proposal;
    if (p == null) return;
    final members = _memberSet(c);
    if (members.isEmpty) return;
    if (!_sameSet(members, p.members)) {
      c.proposal = null;
    } else if (members.every(p.acks.contains)) {
      VisibilityPolicy.apply(c, p.seconds, _now().millisecondsSinceEpoch);
      c.proposal = null;
    }
  }

  /// Proposes how long received messages stay visible after being shown
  /// ([window] null: never hidden). The members decide together: it takes
  /// effect only when everyone accepted ([answerVisibilityProposal]). Until
  /// then the window stays (7 days by default).
  Future<void> proposeVisibilityWindow(String id, Duration? window) async {
    final c = _conversations.all[id];
    if (c == null || c.removed || !_engine.hasGroup(groupId: _gid(id))) {
      throw const NotAllowedException('Conversa indisponível.');
    }
    final seconds = window == null ? 0 : window.inSeconds.clamp(1, maxVisibilityWindow.inSeconds);
    if (seconds == c.visibilitySeconds && c.proposal == null) return;
    final pid = _backend.newEnvelopeId(id);
    await _sendPayload(
      id,
      {'t': 'vp', 'pid': pid, 's': seconds},
      onPublished: (c) {
        c.proposal = VisibilityProposal(id: pid, seconds: seconds, proposer: uid, acks: {uid}, members: _memberSet(c));
        _reconcileProposal(c);
      },
    );
  }

  /// A member's answer to the pending proposal. Refusing keeps the window as it is.
  Future<void> answerVisibilityProposal(String id, {required bool accept}) async {
    final p = _conversations.all[id]?.proposal;
    if (p == null || p.acks.contains(uid)) return;
    if (accept) {
      await _sendPayload(
        id,
        {'t': 'va', 'pid': p.id},
        onPublished: (c) {
          if (c.proposal?.id == p.id) {
            c.proposal = c.proposal!.withAck(uid);
            _reconcileProposal(c);
          }
        },
      );
    } else {
      await _sendPayload(
        id,
        {'t': 'vn', 'pid': p.id},
        onPublished: (c) {
          if (c.proposal?.id == p.id) c.proposal = null;
        },
      );
    }
  }

  /// The conversation is on screen: received messages not shown before start
  /// their window now. Call it when the person opens the conversation (and
  /// when new messages arrive while it is open).
  Future<void> markViewed(String id) => _lock.run(() async {
    final c = _conversations.all[id];
    if (c == null || !VisibilityPolicy.startForUnseen(c, _now().millisecondsSinceEpoch)) return;
    await _conversations.save(c);
    _emit();
  });

  /// Asks the person who wrote a hidden message to let me see it again. They
  /// decide ([respondReveal]); until they answer it stays hidden.
  Future<void> requestReveal(String conversationId, String messageId) async {
    final c = _conversations.all[conversationId];
    if (c == null || c.removed || c.visibilitySeconds <= 0) return;
    final m = c.messages.where((m) => m.id == messageId).firstOrNull;
    if (m == null || m.reveal == 'req') return;
    if (!VisibilityPolicy.view(c, m, _now().millisecondsSinceEpoch).hidden) return;
    await _sendPayload(
      conversationId,
      {'t': 'rq', 'm': messageId},
      onPublished: (c) {
        final i = c.messages.indexWhere((x) => x.id == messageId);
        if (i >= 0) c.messages[i] = c.messages[i].copyWith(reveal: 'req');
      },
    );
  }

  /// Answers [requester]'s request to see my message again. Approving shows it
  /// to them for the conversation's window; only to them.
  Future<void> respondReveal(String conversationId, String messageId, String requester, {required bool approve}) async {
    final c = _conversations.all[conversationId];
    if (c == null || !c.revealRequests.any((r) => r.messageId == messageId && r.requester == requester)) return;
    await _sendPayload(conversationId, {
      't': 'rs',
      'm': messageId,
      'to': requester,
      'ok': approve,
    }, onPublished: (c) => c.revealRequests.removeWhere((r) => r.messageId == messageId && r.requester == requester));
  }

  /// Deletes an ended conversation (one this device left or was removed from)
  /// from this device. Only the person decides this, nothing else deletes it.
  Future<void> deleteConversation(String id) => _lock.run(() async {
    final c = _conversations.all[id];
    if (c == null || !c.removed) throw const NotAllowedException('Saia da conversa antes de apagá-la.');
    await _conversations.remove(id);
    _emit();
  });

  /// Erases all local keys and history (logout / account switch).
  Future<void> wipe() async {
    await dispose();
    await _store.wipe();
  }

  static Uint8List _gid(String id) => utf8.encode(id);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
