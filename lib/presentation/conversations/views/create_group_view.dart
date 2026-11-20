import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/entities/user_profile.dart';
import '../../../domain/services/messaging_service.dart';
import '../view_models/conversations_view_model.dart';
import 'nickname_picker.dart';
import 'package:chatminusis_components/chatminusis_components.dart';

/// Pops with the new conversation id.
class CreateGroupView extends StatefulWidget {
  const CreateGroupView({super.key});

  @override
  State<CreateGroupView> createState() => _CreateGroupViewState();
}

class _CreateGroupViewState extends State<CreateGroupView> {
  final _title = TextEditingController();
  final List<UserProfile> _members = [];
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _add(ConversationsViewModel vm) async {
    final p = await pickByNickname(context, vm.findByNickname);
    if (p == null || p.uid == vm.myUid || _members.any((m) => m.uid == p.uid)) return;
    if (_members.length + 2 > maxGroupMembers) return;
    setState(() => _members.add(p));
  }

  Future<void> _create(ConversationsViewModel vm) async {
    final title = _title.text.trim();
    if (title.isEmpty || _members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dê um nome e adicione pessoas.')));
      return;
    }
    setState(() => _busy = true);
    String? id;
    final error = await vm.run(
      () async => id = await vm.messaging.createGroup(title, _members.map((m) => m.uid).toList()),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    } else {
      Navigator.of(context).pop(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.read<ConversationsViewModel>();
    return Scaffold(
      appBar: AppBar(title: const Text('Novo grupo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PrivateTextField(
            controller: _title,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Nome do grupo',
              helperText: 'O nome é cifrado: o servidor não o vê.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _members)
                InputChip(label: Text('@${m.nickname}'), onDeleted: () => setState(() => _members.remove(m))),
              ActionChip(avatar: const Icon(Icons.add), label: const Text('Adicionar'), onPressed: () => _add(vm)),
            ],
          ),
          const SizedBox(height: 24),
          _busy
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton(onPressed: () => _create(vm), child: const Text('Criar grupo')),
        ],
      ),
    );
  }
}
