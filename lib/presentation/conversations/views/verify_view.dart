import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../domain/services/messaging_service.dart';
import '../view_models/conversations_view_model.dart';

/// Lists the other members and their identity-key status.
class VerifyView extends StatelessWidget {
  const VerifyView({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    final others = vm.byId(conversationId)?.memberUids.where((m) => m != vm.myUid).toList() ?? const [];
    if (others.length == 1) return SafetyNumberView(otherUid: others.single);
    return Scaffold(
      appBar: AppBar(title: const Text('Verificar segurança')),
      body: ListView(
        children: [
          for (final uid in others)
            ListTile(
              leading: _StatusIcon(vm.messaging.keyStatus(uid)),
              title: Text(vm.nameOf(uid)),
              subtitle: Text(_statusText(vm.messaging.keyStatus(uid))),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChangeNotifierProvider.value(
                    value: vm,
                    child: SafetyNumberView(otherUid: uid),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _statusText(KeyStatus s) => switch (s) {
  KeyStatus.verified => 'Verificado',
  KeyStatus.pinned => 'Não verificado',
  KeyStatus.changed => 'A chave mudou: verifique novamente',
  KeyStatus.unknown => 'Desconhecido',
};

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);
  final KeyStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    KeyStatus.verified => const Icon(Icons.verified_user, color: Colors.green),
    KeyStatus.changed => const Icon(Icons.warning_amber, color: Colors.orange),
    _ => const Icon(Icons.shield_outlined),
  };
}

/// Shows the 60-digit safety number and its QR code for one person.
class SafetyNumberView extends StatelessWidget {
  const SafetyNumberView({super.key, required this.otherUid});

  final String otherUid;

  static String format(String number) {
    final groups = [for (var i = 0; i < number.length; i += 5) number.substring(i, i + 5)];
    return [for (var i = 0; i < groups.length; i += 4) groups.skip(i).take(4).join('  ')].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    final status = vm.messaging.keyStatus(otherUid);
    final name = vm.nameOf(otherUid);
    return Scaffold(
      appBar: AppBar(title: Text('Segurança com $name')),
      body: FutureBuilder<String?>(
        future: vm.messaging.safetyNumberWith(otherUid),
        builder: (context, snap) {
          final number = snap.data;
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (number == null) return const Center(child: Text('Ainda não há chave desta pessoa.'));
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (status == KeyStatus.changed)
                const Card(
                  color: Color(0xFFFFF3E0),
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'A chave desta pessoa mudou. Isso acontece quando ela troca de aparelho ou reinstala o app, '
                      'mas também pode indicar um ataque. Confirme o número abaixo com ela antes de confiar.',
                    ),
                  ),
                ),
              Center(
                child: QrImageView(data: 'chatminusis-safety:v1:$number', size: 200, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 16),
              SelectableText(
                format(number),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1.5, height: 1.6),
              ),
              const SizedBox(height: 16),
              Text(
                'Compare este número com o que aparece no aparelho de $name, pessoalmente ou por outro canal confiável. '
                'Se forem iguais, ninguém está interceptando a conversa.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              status == KeyStatus.verified
                  ? OutlinedButton(
                      onPressed: () => vm.messaging.markVerified(otherUid, verified: false),
                      child: const Text('Desmarcar como verificado'),
                    )
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.verified_user),
                      onPressed: () => vm.messaging.markVerified(otherUid),
                      label: const Text('Os números são iguais: marcar como verificado'),
                    ),
            ],
          );
        },
      ),
    );
  }
}
