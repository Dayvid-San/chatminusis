import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/features/security/data/app_lock.dart';

/// Covers the whole app with a lock screen while [AppLock.locked].
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lock = context.read<AppLock>();
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) lock.onBackground();
    if (state == AppLifecycleState.resumed) lock.onForeground();
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    return Stack(
      children: [
        // Keep the app alive underneath but hidden and inert.
        Offstage(
          offstage: lock.locked,
          child: TickerMode(enabled: !lock.locked, child: widget.child),
        ),
        if (lock.locked)
          Material(
            child: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 64),
                    const SizedBox(height: 16),
                    const Text('Chatminusis está bloqueado'),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Desbloquear'),
                      onPressed: lock.unlock,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
