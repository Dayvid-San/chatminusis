import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/conversation.dart';
import '../../../domain/entities/user_profile.dart';
import '../../../domain/repositories/profile_repository.dart';
import '../../../domain/services/messaging_service.dart';

/// Conversation list, names of people and the actions that create or change
/// conversations. Wraps [MessagingService] for the UI.
class ConversationsViewModel extends ChangeNotifier {
  ConversationsViewModel(this.messaging, this._profiles) {
    _sub = messaging.changes.listen((_) => _refresh());
    _refresh();
  }

  final MessagingService messaging;
  final ProfileRepository _profiles;
  final Map<String, UserProfile?> _names = {};
  final Set<String> _loading = {};
  StreamSubscription<void>? _sub;
  List<ConversationSummary> _items = [];

  List<ConversationSummary> get items => _items;
  String get myUid => messaging.uid;

  void _refresh() {
    _items = messaging.conversations();
    for (final c in _items) {
      c.memberUids.forEach(_resolve);
    }
    notifyListeners();
  }

  void _resolve(String uid) {
    if (_names.containsKey(uid) || _loading.contains(uid) || uid.isEmpty) return;
    _loading.add(uid);
    _profiles
        .getProfile(uid)
        .then((p) {
          _names[uid] = p;
          notifyListeners();
        })
        .catchError((Object _) {})
        .whenComplete(() => _loading.remove(uid));
  }

  UserProfile? profile(String uid) {
    _resolve(uid);
    return _names[uid];
  }

  String nameOf(String uid) {
    if (uid == myUid) return 'Você';
    final p = profile(uid);
    return p == null ? '…' : p.displayName;
  }

  String titleOf(ConversationSummary c) {
    if (c.type == ConversationType.group) return c.title ?? 'Grupo';
    final other = c.memberUids.firstWhere((m) => m != myUid, orElse: () => '');
    if (other.isEmpty) {
      // Waiting for the Welcome: the other uid is part of the direct id.
      final parts = c.id.substring(2).split('_');
      return nameOf(parts.firstWhere((p) => p != myUid, orElse: () => ''));
    }
    return nameOf(other);
  }

  ConversationSummary? byId(String id) => messaging.conversation(id);
  List<DecryptedMessage> messagesOf(String id) => messaging.messages(id);

  /// Runs an action and turns known failures into a message for the user.
  Future<String?> run(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on NoKeyPackagesException catch (e) {
      final names = e.uids.map(nameOf).join(', ');
      return '$names ainda não abriu o app para gerar chaves de criptografia.';
    } on NotAllowedException catch (e) {
      return e.reason;
    } catch (_) {
      return 'Não foi possível concluir. Tente novamente.';
    }
  }

  Future<UserProfile?> findByNickname(String nickname) => _profiles.findByNickname(nickname);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
