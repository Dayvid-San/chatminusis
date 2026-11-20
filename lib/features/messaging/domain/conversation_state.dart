import 'dart:convert';

import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/security/domain/secure_store.dart';

/// Everything this device keeps about one conversation (stored sealed in the
/// vault): its messages, title, visibility window and delivery bookkeeping.
class ConversationState {
  ConversationState({required this.id, required this.type});

  final String id;
  ConversationType type;
  String? title;
  int joinedEpoch = 0;
  int lastRotation = 0;
  bool removed = false;

  /// Seconds a received message stays visible after being shown; 0 = always.
  int visibilitySeconds = 0;
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
    'vis': visibilitySeconds,
    'processed': processed.toList(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory ConversationState.fromJson(Map<String, Object?> j) {
    final c = ConversationState(id: j['id'] as String, type: ConversationType.values.byName(j['type'] as String))
      ..title = j['title'] as String?
      ..joinedEpoch = j['joined'] as int? ?? 0
      ..lastRotation = j['rot'] as int? ?? 0
      ..removed = j['removed'] as bool? ?? false
      ..visibilitySeconds = j['vis'] as int? ?? 0;
    c.processed.addAll((j['processed'] as List? ?? const []).cast<String>());
    c.messages.addAll(
      (j['messages'] as List? ?? const []).map((m) => DecryptedMessage.fromJson((m as Map).cast<String, Object?>())),
    );
    return c;
  }
}

/// All conversations of this device, persisted in the [SecureStore].
class ConversationStore {
  ConversationStore(this._store);

  final SecureStore _store;
  final Map<String, ConversationState> all = {};

  Future<void> load() async {
    final index = await _store.read('convs');
    if (index == null) return;
    for (final id in (jsonDecode(utf8.decode(index)) as List).cast<String>()) {
      final raw = await _store.read('conv/$id');
      if (raw == null) continue;
      all[id] = ConversationState.fromJson(jsonDecode(utf8.decode(raw)) as Map<String, Object?>);
    }
  }

  Future<void> save(ConversationState c) async {
    all[c.id] = c;
    await _store.write('conv/${c.id}', utf8.encode(jsonEncode(c.toJson())));
    await _writeIndex();
  }

  /// Forgets a conversation (the person deleted it).
  Future<void> remove(String id) async {
    all.remove(id);
    await _store.delete('conv/$id');
    await _writeIndex();
  }

  Future<void> _writeIndex() => _store.write('convs', utf8.encode(jsonEncode(all.keys.toList())));
}
