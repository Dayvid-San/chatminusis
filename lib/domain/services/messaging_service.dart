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

/// Maximum members per group (decision pending with the Owner; default 256).
const maxGroupMembers = 256;

/// Keeps this many KeyPackages published so others can start conversations.
const _keyPackageTarget = 20;
const _keyPackageLowWater = 8;

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
  }) : _backend = backend,
       _store = store,
       _now = clock ?? DateTime.now;

  final ConversationBackend _backend;
  final SecureStore _store;
  final String uid;
  final DateTime Function() _now;

  late ChatCryptoClient _engine;
  late Uint8List _stateKey;
  final Map<String, _Conv> _convs = {};
  final Map<String, List<Envelope>> _buffer = {};
  final Map<String, StreamSubscription<Envelope>> _envelopeSubs = {};
  final Map<String, StreamSubscription<ConversationRecord?>> _recordSubs = {};
  final List<StreamSubscription<Object?>> _subs = [];
  final _changes = StreamController<void>.broadcast();
  final _lock = _Mutex();
  Timer? _purgeTimer;
  bool _started = false;

  Uint8List get _myId => utf8.encode(uid);

  /// Fires whenever conversations or messages change.
  Stream<void> get changes => _changes.stream;

  /// This device's public signature key (identity), as published.
  Uint8List get signaturePublicKey => _engine.signaturePublicKey;

  ChatCryptoClient get engine => _engine;

  // ------------------------------------------------------------ lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _lock.run(() async {
      await _loadOrCreateEngine();
      await _loadConversations();
      await _purgeExpired();
    });
    await _ensureKeyPackages();
    _subs.add(_backend.watchWelcomes(uid).listen((w) => _lock.run(() => _onWelcome(w))));
    _subs.add(_backend.watchConversationIds(uid).listen(_onConversationIds));
    for (final c in _convs.values.where((c) => !c.removed)) {
      _watch(c.id);
    }
    _purgeTimer = Timer.periodic(const Duration(minutes: 1), (_) => _lock.run(_purgeExpired));
    _emit();
  }

  Future<void> dispose() async {
    _purgeTimer?.cancel();
    for (final s in [..._subs, ..._envelopeSubs.values, ..._recordSubs.values]) {
      await s.cancel();
    }
    _subs.clear();
    _envelopeSubs.clear();
    _recordSubs.clear();
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

  Future<void> _ensureKeyPackages() async {
    final count = await _backend.countKeyPackages(uid);
    if (count >= _keyPackageLowWater) return;
    final kps = await _lock.run(() async {
      final kps = await _engine.generateKeyPackages(count: _keyPackageTarget - count);
      await _persistEngine(); // private parts must be saved before publishing
      return kps;
    });
    await _backend.publishKeyPackages(uid, kps);
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
    _recordSubs[id] ??= _backend
        .watchConversation(id)
        .listen((r) => _lock.run(() => _onRecord(id, r)), onError: (_) => _lock.run(() => _onRecord(id, null)));
    if (_engine.hasGroup(groupId: _gid(id))) _watchEnvelopes(id);
  }

  void _watchEnvelopes(String id) {
    _envelopeSubs[id] ??= _backend.watchEnvelopes(id).listen((e) {
      (_buffer[id] ??= []).add(e);
      _lock.run(() => _drain(id));
    });
  }

  Future<void> _onRecord(String id, ConversationRecord? record) async {
    final c = _convs[id];
    if (c == null) return;
    if (record == null || !record.members.containsKey(uid)) {
      // We were removed (or left): forget the keys, keep the local history.
      await _envelopeSubs.remove(id)?.cancel();
      await _recordSubs.remove(id)?.cancel();
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
    if (c == null || queue == null || queue.isEmpty || !_engine.hasGroup(groupId: gid)) return;
    queue.sort((a, b) => a.epoch != b.epoch ? a.epoch.compareTo(b.epoch) : a.id.compareTo(b.id));
    var changed = false;
    while (queue.isNotEmpty && _engine.hasGroup(groupId: gid)) {
      final e = queue.first;
      final local = _engine.epoch(groupId: gid).toInt();
      if (c.processed.contains(e.id)) {
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
              final r = await _engine.process(groupId: gid, message: e.payload);
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
      } else {
        if (e.epoch > local) break; // wait for the commit that opens this epoch
        if (e.sender != uid && e.epoch >= c.joinedEpoch) {
          try {
            final r = await _engine.process(groupId: gid, message: e.payload);
            if (r.kind == IncomingKind.application) {
              _handlePayload(c, e, utf8.decode(r.sender), r.plaintext);
            }
          } catch (_) {
            _addSystem(c, e, 'Mensagem que não pôde ser decifrada.');
          }
        }
        _markProcessed(c, e.id);
      }
      queue.removeAt(0);
      changed = true;
    }
    if (!changed) return;
    await _persistEngine();
    await _saveConv(c);
    if (!c.removed) {
      await _reconcile(c);
      await _rotateIfStale(c);
    }
    _emit();
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
        firstCommit: _commitEnvelope(record.id, out),
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
  Future<void> rotateKeys(String id) async {
    await _withCommitRetry(id, () async {
      final out = await _engine.selfUpdate(groupId: _gid(id));
      await _publishCommit(id, out);
      _convs[id]!.lastRotation = _now().millisecondsSinceEpoch;
      await _saveConv(_convs[id]!);
    });
  }

  Future<void> _rotateIfStale(_Conv c) async {
    final age = _now().millisecondsSinceEpoch - c.lastRotation;
    if (age < _rotationInterval.inMilliseconds) return;
    try {
      final out = await _engine.selfUpdate(groupId: _gid(c.id));
      await _publishCommit(c.id, out);
      c.lastRotation = _now().millisecondsSinceEpoch;
      await _saveConv(c);
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
          await _backend.publishApplication(env, notifyUids: c.record?.members.keys.toList() ?? const []);
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
