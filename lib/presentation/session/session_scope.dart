import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/security/app_lock.dart';
import '../../domain/repositories/backup_backend.dart';
import '../../domain/repositories/conversation_backend.dart';
import '../../domain/repositories/profile_repository.dart';
import '../../domain/repositories/push_registry.dart';
import '../../domain/repositories/secure_store.dart';
import '../../domain/services/backup_service.dart';
import '../../domain/services/messaging_service.dart';
import '../auth/view_models/auth_view_model.dart';
import '../backup/backup_views.dart';
import '../conversations/view_models/conversations_view_model.dart';
import '../conversations/views/home_view.dart';

typedef SecureStoreFactory = Future<SecureStore> Function(String uid);

/// Lives while a user is signed in: opens their encrypted store, starts the
/// MLS messaging service and exposes it to the screens below.
class SessionScope extends StatefulWidget {
  const SessionScope({super.key, required this.uid});

  final String uid;

  @override
  State<SessionScope> createState() => _SessionScopeState();
}

class _SessionScopeState extends State<SessionScope> {
  MessagingService? _messaging;
  ConversationsViewModel? _vm;
  BackupService? _backup;
  SecureStore? _store;
  bool _offerRestore = false;
  Object? _error;
  bool _compromised = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final store = await context.read<SecureStoreFactory>()(widget.uid);
      if (!mounted) return;
      _store = store;
      _backup = BackupService(backend: context.read<BackupBackend>(), store: store, uid: widget.uid);
      // Fresh device with a backup on the account: offer to restore first.
      if (await store.read('mls_state') == null && await _backup!.remoteInfo() != null) {
        if (mounted) setState(() => _offerRestore = true);
        return;
      }
      await _startMessaging();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _startMessaging() async {
    try {
      final store = _store!;
      final messaging = MessagingService(backend: context.read<ConversationBackend>(), store: store, uid: widget.uid);
      await messaging.start();
      _compromised = await deviceLooksCompromised();
      if (mounted) unawaited(context.read<PushRegistry>().register(widget.uid));
      unawaited(_backup!.maybeAutoBackup(messaging));
      if (!mounted) {
        await messaging.dispose();
        return;
      }
      setState(() {
        _messaging = messaging;
        _vm = ConversationsViewModel(messaging, context.read<ProfileRepository>());
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _vm?.dispose();
    _messaging?.dispose();
    super.dispose();
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sair e apagar deste aparelho?'),
        content: const Text(
          'Suas chaves de criptografia e o histórico serão apagados deste aparelho. '
          'Sem um backup, as mensagens antigas não poderão ser recuperadas.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sair e apagar')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final auth = context.read<AuthViewModel>();
    await context.read<PushRegistry>().unregister(widget.uid);
    final messaging = _messaging;
    _messaging = null;
    await messaging?.wipe();
    await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Não foi possível abrir o cofre de chaves deste aparelho.', textAlign: TextAlign.center),
                TextButton(onPressed: () => context.read<AuthViewModel>().signOut(), child: const Text('Sair')),
              ],
            ),
          ),
        ),
      );
    }
    if (_offerRestore) {
      return RestoreView(
        backup: _backup!,
        onReauth: context.read<AuthViewModel>().reauthenticate,
        onDone: (_) {
          setState(() => _offerRestore = false);
          _startMessaging();
        },
      );
    }
    final vm = _vm;
    final messaging = _messaging;
    if (vm == null || messaging == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return MultiProvider(
      providers: [
        Provider<MessagingService>.value(value: messaging),
        ChangeNotifierProvider<ConversationsViewModel>.value(value: vm),
      ],
      child: Builder(
        builder: (context) => HomeView(
          onSignOut: _signOut,
          deviceCompromised: _compromised,
          securityExtras: [BackupTile(backup: _backup!, messaging: messaging)],
        ),
      ),
    );
  }
}
