import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/entities/conversation.dart';
import '../../../domain/entities/user_profile.dart';
import '../../../domain/repositories/profile_repository.dart';
import '../../auth/view_models/auth_view_model.dart';
import '../../profile/views/nickname_view.dart';
import '../../search/view_models/search_view_model.dart';
import '../../search/views/search_view.dart';
import '../../security/security_settings_view.dart';
import '../view_models/conversations_view_model.dart';
import 'conversation_view.dart';
import 'create_group_view.dart';

class HomeView extends StatelessWidget {
  const HomeView({super.key, required this.onSignOut, this.extraActions = const [], this.deviceCompromised = false});

  /// Wipes local keys and signs out.
  final Future<void> Function(BuildContext context) onSignOut;

  /// Extra app bar actions, provided by the composition root.
  final List<Widget> extraActions;

  /// Root/jailbreak detected: show a warning.
  final bool deviceCompromised;

  void _open(BuildContext context, String id) {
    final vm = context.read<ConversationsViewModel>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider.value(
          value: vm,
          child: ConversationView(conversationId: id),
        ),
      ),
    );
  }

  Future<void> _newDirect(BuildContext context) async {
    final vm = context.read<ConversationsViewModel>();
    final profiles = context.read<ProfileRepository>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider(
          create: (_) => SearchViewModel(profiles, vm.myUid),
          child: SearchView(
            onStartConversation: (ctx, UserProfile p) async {
              String? id;
              final error = await vm.run(() async => id = await vm.messaging.startDirect(p.uid));
              if (!ctx.mounted) return;
              if (error != null) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(error)));
                return;
              }
              Navigator.of(ctx).pop();
              if (context.mounted) _open(context, id!);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _newGroup(BuildContext context) async {
    final vm = context.read<ConversationsViewModel>();
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(value: vm, child: const CreateGroupView()),
      ),
    );
    if (id != null && context.mounted) _open(context, id);
  }

  Future<void> _editProfile(BuildContext context) async {
    final uid = context.read<AuthViewModel>().currentUser?.uid;
    if (uid == null) return;
    final profile = await context.read<ProfileRepository>().getProfile(uid);
    if (!context.mounted || profile == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NicknameView(current: profile)));
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversas'),
        actions: [
          ...extraActions,
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'profile' => _editProfile(context),
              'security' => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const SecuritySettingsView())),
              _ => onSignOut(context),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Editar perfil')),
              PopupMenuItem(value: 'security', child: Text('Segurança e privacidade')),
              PopupMenuItem(value: 'logout', child: Text('Sair')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (deviceCompromised)
            const MaterialBanner(
              leading: Icon(Icons.gpp_bad_outlined, color: Colors.red),
              content: Text(
                'Este aparelho parece ter root/jailbreak. Outros apps podem conseguir ler suas mensagens nele.',
              ),
              actions: [SizedBox.shrink()],
            ),
          Expanded(child: _list(context, vm)),
        ],
      ),
      floatingActionButton: _fab(context),
    );
  }

  Widget _list(BuildContext context, ConversationsViewModel vm) {
    return vm.items.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Nenhuma conversa ainda.\nToque em + e busque alguém pelo nickname exato.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : ListView.separated(
            itemCount: vm.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final c = vm.items[i];
              final title = vm.titleOf(c);
              final last = c.lastMessage;
              return ListTile(
                leading: CircleAvatar(
                  child: c.type == ConversationType.group
                      ? const Icon(Icons.group)
                      : Text(title.isEmpty ? '?' : title.characters.first.toUpperCase()),
                ),
                title: Text(title),
                subtitle: Text(
                  c.pendingWelcome
                      ? 'Aguardando troca de chaves…'
                      : last == null
                      ? 'Criptografada de ponta a ponta'
                      : last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: c.membershipMismatch || c.keyChanged
                    ? const Icon(Icons.warning_amber, color: Colors.orange)
                    : null,
                onTap: () => _open(context, c.id),
              );
            },
          );
  }

  Widget _fab(BuildContext context) {
    return FloatingActionButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: const Text('Nova conversa'),
                onTap: () {
                  Navigator.pop(sheet);
                  _newDirect(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.group_add),
                title: const Text('Novo grupo'),
                onTap: () {
                  Navigator.pop(sheet);
                  _newGroup(context);
                },
              ),
            ],
          ),
        ),
      ),
      child: const Icon(Icons.add),
    );
  }
}
