import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/features/messaging/presentation/conversations_view_model.dart';
import 'package:myapp/features/messaging/presentation/nickname_picker.dart';
import 'package:chatminusis_components/chatminusis_components.dart';

class MembersView extends StatelessWidget {
  const MembersView({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    final c = vm.byId(conversationId);
    if (c == null) return const Scaffold();
    void snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

    Future<void> add() async {
      final p = await pickByNickname(context, vm.findByNickname);
      if (p == null) return;
      final error = await vm.run(() => vm.messaging.addMember(conversationId, p.uid));
      if (error != null) snack(error);
    }

    Future<void> rename() async {
      final ctl = TextEditingController(text: c.title);
      final title = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nome do grupo'),
          content: PrivateTextField(controller: ctl, maxLength: 60, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Salvar')),
          ],
        ),
      );
      ctl.dispose();
      if (title == null || title.trim().isEmpty) return;
      final error = await vm.run(() => vm.messaging.rename(conversationId, title));
      if (error != null) snack(error);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Membros (${c.memberUids.length})'),
        actions: [if (c.isAdmin) IconButton(icon: const Icon(Icons.edit), tooltip: 'Renomear', onPressed: rename)],
      ),
      floatingActionButton: c.isAdmin
          ? FloatingActionButton(onPressed: add, tooltip: 'Adicionar', child: const Icon(Icons.person_add))
          : null,
      body: ListView(
        children: [
          for (final uid in c.memberUids)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(vm.nameOf(uid)),
              subtitle: Text(vm.profile(uid) == null ? '' : '@${vm.profile(uid)!.nickname}'),
              trailing: c.isAdmin && uid != vm.myUid
                  ? IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: 'Remover',
                      onPressed: () async {
                        final error = await vm.run(() => vm.messaging.removeMember(conversationId, uid));
                        if (error != null) snack(error);
                      },
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
