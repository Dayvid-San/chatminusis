import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/entities/conversation.dart';
import '../../chat/widgets/message_bubble_widget.dart';
import '../view_models/conversations_view_model.dart';
import 'members_view.dart';
import 'verify_view.dart';
import '../../shared_widgets/private_input.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Duration? _disappear;
  bool _sending = false;
  int _lastCount = 0;

  String get _id => widget.conversationId;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _send(ConversationsViewModel vm) async {
    final text = _input.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    final error = await vm.run(() => vm.messaging.send(_id, text, disappearAfter: _disappear));
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      _snack(error);
    } else {
      _input.clear();
    }
  }

  Future<void> _menu(ConversationsViewModel vm, String action) async {
    switch (action) {
      case 'members':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangeNotifierProvider.value(
              value: vm,
              child: MembersView(conversationId: _id),
            ),
          ),
        );
      case 'verify':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChangeNotifierProvider.value(
              value: vm,
              child: VerifyView(conversationId: _id),
            ),
          ),
        );
      case 'clear':
        final sure = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Limpar o histórico?'),
            content: const Text(
              'As mensagens desta conversa serão apagadas deste aparelho. '
              'Não existe cópia em nenhum outro lugar: não dá para recuperar. '
              'A outra pessoa mantém a cópia dela.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
            ],
          ),
        );
        if (sure == true) await vm.messaging.clearHistory(_id);
      case 'rotate':
        final error = await vm.run(() => vm.messaging.rotateKeys(_id));
        if (mounted) _snack(error ?? 'Chaves renovadas.');
      case 'leave':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Sair da conversa?'),
            content: const Text('Você deixará de receber mensagens. O histórico deste aparelho continua salvo.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sair')),
            ],
          ),
        );
        if (ok != true) return;
        final error = await vm.run(() => vm.messaging.leave(_id));
        if (!mounted) return;
        error == null ? Navigator.of(context).pop() : _snack(error);
    }
  }

  Future<void> _pickTimer() async {
    const options = <(String, Duration?)>[
      ('Desligado', null),
      ('5 minutos', Duration(minutes: 5)),
      ('1 hora', Duration(hours: 1)),
      ('1 dia', Duration(days: 1)),
      ('7 dias', Duration(days: 7)),
    ];
    final picked = await showModalBottomSheet<(String, Duration?)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Mensagens temporárias')),
            for (final o in options)
              ListTile(
                title: Text(o.$1),
                trailing: o.$2 == _disappear ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _disappear = picked.$2);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    final c = vm.byId(_id);
    final messages = vm.messagesOf(_id);
    if (messages.length != _lastCount) {
      _lastCount = messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final isGroup = c?.type == ConversationType.group;
    final ready = c != null && !c.pendingWelcome;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.lock, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text(c == null ? 'Conversa' : vm.titleOf(c), overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_disappear == null ? Icons.timer_off_outlined : Icons.timer_outlined),
            tooltip: 'Mensagens temporárias',
            onPressed: _pickTimer,
          ),
          PopupMenuButton<String>(
            onSelected: (a) => _menu(vm, a),
            itemBuilder: (_) => [
              if (isGroup) const PopupMenuItem(value: 'members', child: Text('Membros')),
              const PopupMenuItem(value: 'verify', child: Text('Verificar segurança')),
              const PopupMenuItem(value: 'rotate', child: Text('Renovar chaves')),
              const PopupMenuItem(value: 'clear', child: Text('Limpar histórico neste aparelho')),
              if (isGroup) const PopupMenuItem(value: 'leave', child: Text('Sair do grupo')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (c?.keyChanged ?? false)
            MaterialBanner(
              content: const Text('A chave de segurança de um participante mudou.'),
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              actions: [TextButton(onPressed: () => _menu(vm, 'verify'), child: const Text('Verificar'))],
            ),
          if (c?.membershipMismatch ?? false)
            const MaterialBanner(
              content: Text('Os membros do servidor diferem do grupo criptografado. Verifique a segurança.'),
              leading: Icon(Icons.warning_amber, color: Colors.orange),
              actions: [SizedBox.shrink()],
            ),
          Expanded(
            child: !ready && messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Aguardando a troca de chaves com a outra pessoa…', textAlign: TextAlign.center),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final m = messages[i];
                      if (m.senderUid.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            m.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        );
                      }
                      return MessageBubbleWidget(
                        message: m,
                        isMe: m.outgoing,
                        senderName: isGroup && !m.outgoing ? vm.nameOf(m.senderUid) : null,
                        onDelete: () => vm.messaging.deleteMessage(_id, m.id),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: PrivateTextField(
                      controller: _input,
                      enabled: ready,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 4000,
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: _disappear == null ? 'Mensagem' : 'Mensagem temporária',
                        counterText: '',
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      onSubmitted: (_) => _send(vm),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: ready && !_sending ? () => _send(vm) : null,
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
