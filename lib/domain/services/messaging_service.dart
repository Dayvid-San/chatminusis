import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';

import '../entities/conversation.dart';
import '../repositories/conversation_backend.dart';
import '../repositories/secure_store.dart';

class NoKeyPackagesException implements Exception {
  const NoKeyPackagesException(this.uids);

  /// Users that have no KeyPackage available (they need to open the app).
  final List<String> uids;
}

class NotAllowedException implements Exception {
  const NotAllowedException(this.reason);
  final String reason;
}

/// Trust state of a contact's identity key on this device.
enum KeyStatus {
  /// Never seen in any conversation.
  unknown,

  /// Pinned on first sight (trust on first use), not verified in person.
  pinned,

  /// Safety number confirmed by the user.
  verified,

  /// Differs from the pinned key: reinstall, new phone, or an attack.
  changed,
}

/// Maximum members per group (decision pending with the Owner; default 256).
const maxGroupMembers = 256;

/// Keeps this many KeyPackages published so others can start conversations.
const _keyPackageTarget = 20;
const _keyPackageLowWater = 8;

/// KeyPackages expire (about 90 days). Replace the whole pool well before.
const _poolMaxAge = Duration(days: 45);

/// The reusable last-resort KeyPackage is renewed this often.
const _lastResortMaxAge = Duration(days: 30);

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
  final Map<String, _Conv> _convs = {};
  final Map<String, _Pin> _pins = {};
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
  final _lock = _Mutex();
  Timer? _purgeTimer;
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
      await _loadConversations();
      await _loadPins();
      await _purgeExpired();
    });
    await _ensureKeyPackages();
    _subs.add(_backend.watchWelcomes(uid).listen((w) => _enqueue(() => _onWelcome(w))));
    _subs.add(_backend.watchConversationIds(uid).listen(_onConversationIds));
    for (final c in _convs.values.where((c) => !c.removed)) {
      _watch(c.id);
    }
    _purgeTimer = Timer.periodic(const Duration(minutes: 1), (_) => _enqueue(_purgeExpired));
    _emit();
  }

  Future<void> dispose() async {
    _disposed = true;
    _purgeTimer?.cancel();
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

  Future<int?> _readInt(String name) async {
    final raw = await _store.read(name);
    return raw == null ? null : int.tryParse(utf8.decode(raw));
  }

  Future<void> _writeInt(String name, int value) => _store.write(name, utf8.encode('$value'));

  /// Keeps single-use KeyPackages and the last-resort one published and fresh.
  Future<void> _ensureKeyPackages() async {
    final nowMs = _now().millisecondsSinceEpoch;
    final poolAt = await _readInt('kp_pool_at');
    final stale = poolAt != null && nowMs - poolAt > _poolMaxAge.inMilliseconds;
    if (stale) await _backend.clearKeyPackages(uid); // pool and last resort: both are about to expire

    final count = stale ? 0 : await _backend.countKeyPackages(uid);
    if (count < _keyPackageLowWater) {
      final kps = await _lock.run(() async {
        final kps = await _engine.generateKeyPackages(count: _keyPackageTarget - count);
        await _persistEngine(); // private parts must be saved before publishing
        return kps;
      });
      await _backend.publishKeyPackages(uid, kps);
      if (stale || poolAt == null) await _writeInt('kp_pool_at', nowMs);
    }

    final lastAt = await _readInt('last_resort_at');
    if (stale || lastAt == null || nowMs - lastAt > _lastResortMaxAge.inMilliseconds) {
      final kp = await _lock.run(() async {
        final kp = await _engine.generateLastResortKeyPackage();
        await _persistEngine();
        return kp;
      });
      await _backend.publishLastResortKeyPackage(uid, kp);
      await _writeInt('last_resort_at', nowMs);
    }
  }

  Future<void> _loadConversations() async {
    final index = await _store.read('convs');
    if (index == null) return;
    for (final id in (jsonDecode(utf8.decode(index)) as List).cast<String>()) {
      final raw = await _store.read('conv/$id');
      if (raw == null) continue;
      _convs[id] = _Conv.fromJson(jsonDecode(utf8.decode(raw)) as Map<String, Object?>);
    }
  }

  Future<void> _saveConv(_Conv c) async {
    _convs[c.id] = c;
    await _store.write('conv/${c.id}', utf8.encode(jsonEncode(c.toJson())));
    await _store.write('convs', utf8.encode(jsonEncode(_convs.keys.toList())));
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------ identity pins

  Future<void> _loadPins() async {
    final raw = await _store.read('pins');
    if (raw == null) return;
    (jsonDecode(utf8.decode(raw)) as Map<String, Object?>).forEach((uid, v) {
      _pins[uid] = _Pin.fromJson((v as Map).cast<String, Object?>());
    });
  }

  Future<void> _savePins() =>
      _store.write('pins', utf8.encode(jsonEncode({for (final e in _pins.entries) e.key: e.value.toJson()})));

  /// Pins every member's key on first sight and flags changes afterwards.
  Future<void> _checkKeys(_Conv c) async {
    final gid = _gid(c.id);
    if (!_engine.hasGroup(groupId: gid)) return;
    var changed = false;
    for (final m in _engine.memberKeys(groupId: gid)) {
      final who = utf8.decode(m.identity);
      if (who == uid) continue;
      final key = base64Encode(m.signatureKey);
      final pin = _pins[who];
      if (pin == null) {
        _pins[who] = _Pin(key: key);
        changed = true;
      } else if (pin.key != key && pin.pendingKey != key) {
        pin
          ..pendingKey = key
          ..verified = false;
        changed = true;
        for (final other in _convs.values.where((x) => !x.removed && _hasMember(x, who))) {
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
          await _saveConv(other);
        }
      }
    }
    if (changed) await _savePins();
  }

  bool _hasMember(_Conv c, String who) {
    final gid = _gid(c.id);
    return _engine.hasGroup(groupId: gid) && _engine.members(groupId: gid).any((m) => utf8.decode(m) == who);
  }

  KeyStatus keyStatus(String otherUid) {
    final pin = _pins[otherUid];
    if (pin == null) return KeyStatus.unknown;
    if (pin.pendingKey != null) return KeyStatus.changed;
    return pin.verified ? KeyStatus.verified : KeyStatus.pinned;
  }

  /// 60-digit number both people must see identically. Uses the key currently
  /// in use (the new one, if it changed). Null if the person was never seen.
  Future<String?> safetyNumberWith(String otherUid) async {
    final pin = _pins[otherUid];
    if (pin == null) return null;
    return safetyNumber(
      myIdentity: _myId,
      myKey: _engine.signaturePublicKey,
      theirIdentity: utf8.encode(otherUid),
      theirKey: base64Decode(pin.pendingKey ?? pin.key),
    );
  }

  /// The user compared safety numbers: trust the current key (accepting a
  /// change, if there was one).
  Future<void> markVerified(String otherUid, {bool verified = true}) async {
    final pin = _pins[otherUid];
    if (pin == null) return;
    if (pin.pendingKey != null) {
      pin
        ..key = pin.pendingKey!
        ..pendingKey = null;
    }
    pin.verified = verified;
    await _lock.run(_savePins);
    _emit();
  }

  // --------------------------------------------------------------- reads

  List<ConversationSummary> conversations() {
    final list = _convs.values.where((c) => !c.removed).map(_summary).toList();
    int last(ConversationSummary s) => s.lastMessage?.timestamp ?? 0;
    list.sort((a, b) => last(b).compareTo(last(a)));
    return list;
  }

  ConversationSummary? conversation(String id) {
    final c = _convs[id];
    return c == null ? null : _summary(c);
  }

  List<DecryptedMessage> messages(String conversationId) =>
      List.unmodifiable(_convs[conversationId]?.messages ?? const <DecryptedMessage>[]);

  ConversationSummary _summary(_Conv c) {
    final has = _engine.hasGroup(groupId: _gid(c.id));
    final mls = has ? _engine.members(groupId: _gid(c.id)).map(utf8.decode).toList() : <String>[];
    final server = c.record?.members.keys.toSet();
    return ConversationSummary(
      id: c.id,
      type: c.type,
      memberUids: has ? mls : (server?.toList() ?? const []),
      isAdmin: c.record?.isAdmin(uid) ?? false,
      title: c.title,
      lastMessage: c.messages.isEmpty ? null : c.messages.last,
      pendingWelcome: !has,
      membershipMismatch: has && server != null && !_sameSet(server, mls.toSet()),
      keyChanged: mls.any((m) => m != uid && keyStatus(m) == KeyStatus.changed),
    );
  }

  // ------------------------------------------------------- server events

  void _onConversationIds(List<String> ids) {
    for (final id in ids) {
      if (!_convs.containsKey(id) || _convs[id]!.removed) {
        final type = id.startsWith('d_') ? ConversationType.direct : ConversationType.group;
        _convs[id] = _Conv(id: id, type: type);
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
      final c = _convs[id];
      if (c != null && !c.removed && !_engine.hasGroup(groupId: _gid(id)) && _rejoinAsked.add(id)) {
        unawaited(_backend.requestRejoin(id, uid).catchError((Object _) {}));
      }
    });
  }

  // ------------------------------------------------- lost-commit recovery

  bool _isBehind(_Conv c) {
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
  void _watchGap(_Conv c) {
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
    final c = _convs[id];
    if (c == null || !_isBehind(c)) return; // caught up in the meantime
    await _dropGroupAndRejoin(c, 'Você ficou muito tempo offline. Reconectando à conversa…');
  }

  /// Forgets the group state (keeping the history) and asks to be re-invited.
  Future<void> _dropGroupAndRejoin(_Conv c, String notice) async {
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
    await _saveConv(c);
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
      final c = _convs[id];
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
      final title = c.title;
      if (title != null) await _sendPayload(id, {'t': 'meta', 'title': title});
      _emit();
    } catch (_) {
      // Lost a race or offline: the request stays and is retried on the next change.
    } finally {
      _repairing.remove(key);
    }
  }

  Future<void> _onRecord(String id, ConversationRecord? record) async {
    final c = _convs[id];
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
      await _saveConv(c);
      _emit();
      return;
    }
    c.record = record;
    await _saveConv(c);
    _watchGap(c);
    await _reconcile(c);
    _emit();
  }

  /// Admins remove from the MLS group anyone the server no longer lists
  /// (e.g. members who left), so they stop receiving keys.
  Future<void> _reconcile(_Conv c) async {
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
      final c = _convs[w.conversationId] ?? _Conv(id: w.conversationId, type: record.type);
      c
        ..type = record.type
        ..record = record
        ..removed = false
        ..joinedEpoch = _engine.epoch(groupId: gid).toInt()
        ..lastRotation = _now().millisecondsSinceEpoch;
      await _saveConv(c);
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
    final c = _convs[id];
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
    await _persistEngine();
    await _saveConv(c);
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
  bool _canCommit(_Conv c) => c.record?.isAdmin(uid) ?? false;

  /// Admins turn members' stored key-rotation proposals into one commit.
  Future<void> _commitPendingProposals(_Conv c) async {
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

  void _markProcessed(_Conv c, String id) {
    c.processed.add(id);
    if (c.processed.length > 5000) c.processed.remove(c.processed.first);
  }

  void _handlePayload(_Conv c, Envelope e, String sender, Uint8List plaintext) {
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
        final ttl = p['x'];
        final received = _now().millisecondsSinceEpoch;
        c.messages.add(
          DecryptedMessage(
            id: e.id,
            conversationId: c.id,
            senderUid: sender,
            text: text,
            timestamp: e.timestamp == 0 ? received : e.timestamp,
            outgoing: false,
            expiresAt: ttl is int && ttl > 0 ? received + ttl * 1000 : null,
          ),
        );
      case 'meta':
        // Only admins may rename a group.
        final title = p['title'];
        if (c.type == ConversationType.group && title is String && (c.record?.isAdmin(sender) ?? false)) {
          c.title = title.length > 60 ? title.substring(0, 60) : title;
        }
    }
  }

  void _addSystem(_Conv c, Envelope e, String text) {
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
        _convs.putIfAbsent(id, () => _Conv(id: id, type: ConversationType.direct));
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
      _convs[id]!.title = title.trim();
      await _saveConv(_convs[id]!);
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
    final c = _Conv(id: record.id, type: record.type)
      ..record = record
      ..joinedEpoch = 1
      ..lastRotation = _now().millisecondsSinceEpoch;
    await _persistEngine();
    await _saveConv(c);
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
    final c = _convs[id]!;
    _markProcessed(c, env.id);
    await _persistEngine();
    await _saveConv(c);
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
    final title = _convs[id]?.title;
    if (title != null) await _sendPayload(id, {'t': 'meta', 'title': title});
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
    await _lock.run(() => _saveConv(c));
    await _sendPayload(id, {'t': 'meta', 'title': title.trim()});
  }

  /// Rotates this member's keys in the conversation (post-compromise security).
  /// Admins commit directly; ordinary members send a proposal that an admin
  /// commits (the server does not let them commit).
  Future<void> rotateKeys(String id) async {
    final c = _convs[id];
    if (c != null && c.record != null && !_canCommit(c)) {
      await _lock.run(() => _proposeRotation(c));
      return;
    }
    await _withCommitRetry(id, () async {
      final out = await _engine.selfUpdate(groupId: _gid(id));
      await _publishCommit(id, out);
      _convs[id]!.lastRotation = _now().millisecondsSinceEpoch;
      await _saveConv(_convs[id]!);
    });
  }

  Future<void> _proposeRotation(_Conv c) async {
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
    await _saveConv(c);
  }

  Future<void> _rotateIfStale(_Conv c) async {
    final age = _now().millisecondsSinceEpoch - c.lastRotation;
    if (age < _rotationInterval.inMilliseconds || c.record == null) return;
    try {
      if (_canCommit(c)) {
        final out = await _engine.selfUpdate(groupId: _gid(c.id));
        await _publishCommit(c.id, out);
        c.lastRotation = _now().millisecondsSinceEpoch;
        await _saveConv(c);
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

  _Conv _requireAdminGroup(String id) {
    final c = _convs[id];
    if (c == null || c.type != ConversationType.group) throw const NotAllowedException('Conversa inválida.');
    if (!(c.record?.isAdmin(uid) ?? false)) throw const NotAllowedException('Apenas administradores.');
    return c;
  }

  /// Sends a text message. [disappearAfter] makes it vanish on every device.
  Future<void> send(String id, String text, {Duration? disappearAfter}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > 4000) throw const NotAllowedException('Mensagem muito longa.');
    await _sendPayload(
      id,
      {'t': 'msg', 'text': trimmed, if (disappearAfter != null) 'x': disappearAfter.inSeconds},
      localText: trimmed,
      ttl: disappearAfter,
    );
  }

  Future<void> _sendPayload(String id, Map<String, Object?> payload, {String? localText, Duration? ttl}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _lock.run(() async {
          final c = _convs[id];
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
                expiresAt: ttl == null ? null : now + ttl.inMilliseconds,
              ),
            );
          }
          await _persistEngine();
          await _saveConv(c);
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

  /// Removes expired disappearing messages now (also runs every minute).
  Future<void> purgeExpiredNow() => _lock.run(_purgeExpired);

  Future<void> _purgeExpired() async {
    final now = _now().millisecondsSinceEpoch;
    for (final c in _convs.values) {
      final before = c.messages.length;
      c.messages.removeWhere((m) => m.expiresAt != null && m.expiresAt! <= now);
      if (c.messages.length != before) await _saveConv(c);
    }
    _emit();
  }

  /// Erases all local keys and history (logout / account switch).
  Future<void> wipe() async {
    await dispose();
    await _store.wipe();
  }

  static Uint8List _gid(String id) => utf8.encode(id);
}

class _Conv {
  _Conv({required this.id, required this.type});

  final String id;
  ConversationType type;
  String? title;
  int joinedEpoch = 0;
  int lastRotation = 0;
  bool removed = false;
  ConversationRecord? record;
  final Set<String> processed = <String>{};
  final List<DecryptedMessage> messages = [];

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'title': title,
    'joined': joinedEpoch,
    'rot': lastRotation,
    'removed': removed,
    'processed': processed.toList(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory _Conv.fromJson(Map<String, Object?> j) {
    final c = _Conv(id: j['id'] as String, type: ConversationType.values.byName(j['type'] as String))
      ..title = j['title'] as String?
      ..joinedEpoch = j['joined'] as int? ?? 0
      ..lastRotation = j['rot'] as int? ?? 0
      ..removed = j['removed'] as bool? ?? false;
    c.processed.addAll((j['processed'] as List? ?? const []).cast<String>());
    c.messages.addAll(
      (j['messages'] as List? ?? const []).map((m) => DecryptedMessage.fromJson((m as Map).cast<String, Object?>())),
    );
    return c;
  }
}

class _Pin {
  _Pin({required this.key});

  String key;
  String? pendingKey;
  bool verified = false;

  Map<String, Object?> toJson() => {'k': key, 'p': pendingKey, 'v': verified};

  factory _Pin.fromJson(Map<String, Object?> j) => _Pin(key: j['k'] as String)
    ..pendingKey = j['p'] as String?
    ..verified = j['v'] as bool? ?? false;
}

/// Serializes async operations on the MLS state.
class _Mutex {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }
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
