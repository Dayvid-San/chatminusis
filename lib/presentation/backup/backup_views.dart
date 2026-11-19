import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/services/backup_service.dart';
import '../../domain/services/messaging_service.dart';

String backupErrorText(BackupError e) => switch (e) {
  BackupError.noBackup => 'Não há backup nesta conta.',
  BackupError.noServerShare => 'A parte do servidor deste backup não existe mais.',
  BackupError.wrongCode => 'Código de recuperação incorreto.',
  BackupError.wrongAccount => 'Este backup pertence a outra conta.',
  BackupError.invalidCode => 'O código deve ter 52 caracteres (letras e números).',
};

/// Entry in the security screen.
class BackupTile extends StatelessWidget {
  const BackupTile({super.key, required this.backup, required this.messaging});

  final BackupService backup;
  final MessagingService messaging;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.cloud_upload_outlined),
    title: const Text('Backup cifrado'),
    subtitle: const Text('Só abre com seu código de recuperação e sua conta.'),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BackupView(backup: backup, messaging: messaging),
      ),
    ),
  );
}

class BackupView extends StatefulWidget {
  const BackupView({super.key, required this.backup, required this.messaging});

  final BackupService backup;
  final MessagingService messaging;

  @override
  State<BackupView> createState() => _BackupViewState();
}

class _BackupViewState extends State<BackupView> {
  bool? _enabled;
  DateTime? _last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await widget.backup.isEnabled();
    final last = await widget.backup.lastBackup();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _last = last;
      });
    }
  }

  Future<void> _busyRun(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } on BackupException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(backupErrorText(e.error))));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível concluir agora.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _enable() async {
    late String code;
    await _busyRun(() async => code = await widget.backup.enable(widget.messaging), 'Backup criado.');
    if (!mounted || !(_enabled ?? false)) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CodeDialog(code: code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup cifrado')),
      body: enabled == null || _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'O backup guarda suas chaves e seu histórico cifrados. Para abrir, são necessários '
                  'o seu código de recuperação (que só você tem) e a sua conta. Nem nós conseguimos abrir. '
                  'Se perder o código, o backup não poderá ser recuperado.',
                ),
                const SizedBox(height: 24),
                if (!enabled)
                  ElevatedButton.icon(
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Ativar backup'),
                    onPressed: _enable,
                  )
                else ...[
                  ListTile(
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: const Text('Backup ativado'),
                    subtitle: Text(_last == null ? 'Ainda não concluído' : 'Último: ${_last!.toLocal()}'),
                  ),
                  ElevatedButton(
                    onPressed: () => _busyRun(() => widget.backup.backupNow(widget.messaging), 'Backup atualizado.'),
                    child: const Text('Fazer backup agora'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _enable, child: const Text('Gerar novo código (invalida o antigo)')),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _busyRun(widget.backup.disable, 'Backup apagado do servidor.'),
                    child: const Text('Desativar e apagar backup', style: TextStyle(color: Colors.red)),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Shows the recovery code once and asks the user to confirm they wrote it down.
class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.code});
  final String code;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  String get _lastGroup => widget.code.split('-').last;

  @override
  Widget build(BuildContext context) {
    final ok = _confirm.text.trim().toUpperCase() == _lastGroup;
    return AlertDialog(
      title: const Text('Seu código de recuperação'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Anote em papel e guarde em lugar seguro. Ele não será mostrado de novo.'),
            const SizedBox(height: 12),
            SelectableText(
              widget.code.replaceAll('-', ' '),
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Digite o último bloco para confirmar'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: ok
              ? () {
                  Clipboard.setData(const ClipboardData(text: '')); // never leave the code in the clipboard
                  Navigator.pop(context);
                }
              : null,
          child: const Text('Anotei'),
        ),
      ],
    );
  }
}

/// Offered on a fresh device when the account has a backup.
class RestoreView extends StatefulWidget {
  const RestoreView({super.key, required this.backup, required this.onDone});

  final BackupService backup;

  /// Called after restoring (true) or choosing to start fresh (false).
  final void Function(bool restored) onDone;

  @override
  State<RestoreView> createState() => _RestoreViewState();
}

class _RestoreViewState extends State<RestoreView> {
  final _code = TextEditingController();
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.backup.restore(_code.text);
      widget.onDone(true);
    } on BackupException catch (e) {
      setState(() => _error = backupErrorText(e.error));
    } catch (_) {
      setState(() => _error = 'Não foi possível restaurar agora.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Restaurar backup')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Esta conta tem um backup cifrado. Digite o código de recuperação para trazer suas conversas.'),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          minLines: 2,
          maxLines: 3,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Código de recuperação', border: OutlineInputBorder()),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 20),
        if (_busy)
          const Center(child: CircularProgressIndicator())
        else ...[
          ElevatedButton(onPressed: _restore, child: const Text('Restaurar')),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => widget.onDone(false),
            child: const Text('Começar sem o backup (conversas antigas ficam inacessíveis neste aparelho)'),
          ),
        ],
      ],
    ),
  );
}
