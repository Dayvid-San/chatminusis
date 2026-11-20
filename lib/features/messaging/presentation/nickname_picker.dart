import 'package:flutter/material.dart';

import 'package:myapp/core/utils/nickname.dart';
import 'package:myapp/features/profile/domain/user_profile.dart';
import 'package:chatminusis_components/chatminusis_components.dart';

/// Asks for an exact nickname and resolves it. Returns null if cancelled or not found.
Future<UserProfile?> pickByNickname(
  BuildContext context,
  Future<UserProfile?> Function(String nickname) find, {
  String title = 'Adicionar pessoa',
}) async {
  final ctl = TextEditingController();
  final nick = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: PrivateTextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nickname exato', prefixText: '@'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Buscar')),
      ],
    ),
  );
  ctl.dispose();
  if (nick == null) return null;
  final normalized = Nickname.normalize(nick);
  final problem = Nickname.validate(normalized);
  if (problem != null) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
    return null;
  }
  final found = await find(normalized);
  if (found == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ninguém com esse nickname.')));
  }
  return found;
}
