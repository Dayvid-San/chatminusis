import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/security/app_lock.dart';
import '../../domain/repositories/conversation_backend.dart';
import '../../domain/repositories/profile_repository.dart';
import '../../domain/repositories/push_registry.dart';
import '../../domain/repositories/secure_store.dart';
import '../../domain/services/messaging_service.dart';
import '../auth/view_models/auth_view_model.dart';
import '../conversations/view_models/conversations_view_model.dart';
import '../conversations/views/home_view.dart';

typedef SecureStoreFactory = Future<SecureStore> Function(String uid);

/// Lives while a user is signed in: opens their encrypted store, starts the
/// MLS messaging service and exposes it to the screens below.
class SessionScope extends StatefulWidget {
  const SessionScope({super.key, required this.uid, this.securityExtrasBuilder});

  final String uid;

  /// Builds extra entries for the security screen once messaging is running.
  final List<Widget> Function(BuildContext context, MessagingService messaging)? securityExtrasBuilder;

  @override
  State<SessionScope> createState() => _SessionScopeState();
}

class _SessionScopeState extends State<SessionScope> {
  MessagingService? _messaging;
  ConversationsViewModel? _vm;
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
      final messaging = MessagingService(backend: context.read<ConversationBackend>(), store: store, uid: widget.uid);
      await messaging.start();
      _compromised = await deviceLooksCompromised();
      if (mounted) unawaited(context.read<PushRegistry>().register(widget.uid));
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
          securityExtras: widget.securityExtrasBuilder?.call(context, messaging) ?? const [],
        ),
      ),
    );
  }
}
