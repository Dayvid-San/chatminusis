import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/features/security/data/app_lock.dart';

class SecuritySettingsView extends StatelessWidget {
  const SecuritySettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    return Scaffold(
      appBar: AppBar(title: const Text('Segurança e privacidade')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Bloqueio do app'),
            subtitle: const Text('Pede biometria ou o PIN do aparelho ao abrir e após 30 s em segundo plano.'),
            value: lock.enabled,
            onChanged: (v) async {
              final ok = await lock.setEnabled(v);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Não foi possível ativar: configure um bloqueio de tela no aparelho.')),
                );
              }
            },
          ),
          const ListTile(
            leading: Icon(Icons.screenshot_monitor),
            title: Text('Proteção de tela'),
            subtitle: Text('Prints e gravação de tela bloqueados no Android; conteúdo oculto no multitarefa.'),
          ),
          const ListTile(
            leading: Icon(Icons.enhanced_encryption_outlined),
            title: Text('Dados no aparelho'),
            subtitle: Text(
              'Suas mensagens existem só neste aparelho: cifradas (AES-256-GCM), com chave no Keystore/Keychain e fora dos backups do sistema. Se você perder o aparelho, elas se perdem.',
            ),
          ),
        ],
      ),
    );
  }
}
