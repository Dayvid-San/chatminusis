import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/presentation/message_bubble_widget.dart';
import 'package:myapp/features/messaging/presentation/conversations_view_model.dart';
import 'package:myapp/features/messaging/presentation/members_view.dart';
import 'package:myapp/features/messaging/presentation/verify_view.dart';
import 'package:chatminusis_components/chatminusis_components.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
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
    final error = await vm.run(() => vm.messaging.send(_id, text));
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
        final sure = await confirmDialog(
          context,
          title: 'Limpar o histórico?',
          message:
              'As mensagens desta conversa serão apagadas deste aparelho. '
              'Não existe cópia em nenhum outro lugar: não dá para recuperar. '
              'A outra pessoa mantém a cópia dela.',
          confirmLabel: 'Apagar',
        );
        if (sure) await vm.messaging.clearHistory(_id);
      case 'rotate':
        final error = await vm.run(() => vm.messaging.rotateKeys(_id));
        if (mounted) _snack(error ?? 'Chaves renovadas.');
      case 'leave':
        final ok = await confirmDialog(
          context,
          title: 'Sair da conversa?',
          message: 'Você deixará de receber mensagens. O histórico deste aparelho continua salvo.',
          confirmLabel: 'Sair',
        );
        if (!ok) return;
        final error = await vm.run(() => vm.messaging.leave(_id));
        if (!mounted) return;
        error == null ? Navigator.of(context).pop() : _snack(error);
    }
  }

  static String windowLabel(Duration? w) => w == null ? 'sempre visíveis' : durationLabel(w);

  /// Proposes how long what the other people write stays visible after being
  /// shown. The members must agree: it only takes effect when all accept.
  Future<void> _pickWindow(ConversationsViewModel vm, Duration? current) async {
    const options = <(String, Duration?)>[
      ('Sempre visíveis', null),
      ('30 segundos', Duration(seconds: 30)),
      ('5 minutos', Duration(minutes: 5)),
      ('1 hora', Duration(hours: 1)),
      ('1 dia', Duration(days: 1)),
      ('7 dias (padrão)', Duration(days: 7)),
    ];
    final picked = await showModalBottomSheet<(String, Duration?)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Tempo de visualização'),
              subtitle: Text(
                'Depois deste tempo, as mensagens recebidas ficam ocultas neste aparelho. '
                'Não são apagadas: quem as recebeu pode pedir para ver de novo, e quem as enviou aprova ou não. '
                'A mudança só vale quando todos os membros aceitarem; sem acordo, fica em 7 dias.',
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.$1),
                trailing: o.$2 == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.$2 == current) return;
    final error = await vm.run(() => vm.messaging.proposeVisibilityWindow(_id, picked.$2));
    if (mounted) _snack(error ?? 'Proposta enviada. Vale quando todos aceitarem.');
  }

  /// Banners that need an answer from me, or tell me what I am waiting for.
  List<Widget> _pending(ConversationsViewModel vm, ConversationSummary c) {
    final out = <Widget>[];
    final p = c.visibilityProposal;
    if (p != null) {
      final label = windowLabel(p.seconds == 0 ? null : Duration(seconds: p.seconds));
      if (p.acks.contains(vm.myUid)) {
        out.add(
          MaterialBanner(
            content: Text('Aguardando os outros aceitarem o tempo de visualização: $label.'),
            leading: const Icon(Icons.hourglass_empty),
            actions: [
              TextButton(
                onPressed: () => vm.messaging.answerVisibilityProposal(_id, accept: false),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        );
      } else {
        out.add(
          MaterialBanner(
            content: Text('${vm.nameOf(p.proposer)} propôs o tempo de visualização: $label. Você aceita?'),
            leading: const Icon(Icons.timer_outlined),
            actions: [
              TextButton(
                onPressed: () => vm.messaging.answerVisibilityProposal(_id, accept: false),
                child: const Text('Recusar'),
              ),
              TextButton(
                onPressed: () => vm.messaging.answerVisibilityProposal(_id, accept: true),
                child: const Text('Aceitar'),
              ),
            ],
          ),
        );
      }
    }
    if (c.revealRequests.isNotEmpty) {
      final r = c.revealRequests.first;
      final more = c.revealRequests.length - 1;
      out.add(
        MaterialBanner(
          content: Text(
            '${vm.nameOf(r.requester)} pediu para ver de novo uma mensagem sua: “${r.text}”'
            '${more > 0 ? ' (+$more pedido${more > 1 ? 's' : ''})' : ''}',
          ),
          leading: const Icon(Icons.visibility_outlined),
          actions: [
            TextButton(
              onPressed: () => vm.messaging.respondReveal(_id, r.messageId, r.requester, approve: false),
              child: const Text('Negar'),
            ),
            TextButton(
              onPressed: () => vm.messaging.respondReveal(_id, r.messageId, r.requester, approve: true),
              child: const Text('Permitir'),
            ),
          ],
        ),
      );
    }
    return out;
  }

  Widget _message(ConversationsViewModel vm, ConversationSummary? c, DecryptedMessage m, bool isGroup) {
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
    final name = isGroup && !m.outgoing ? vm.nameOf(m.senderUid) : null;
    // Re-read at the moment the window runs out, so it hides by itself.
    return RebuildAt(
      instant: m.viewedUntil == null ? null : DateTime.fromMillisecondsSinceEpoch(m.viewedUntil!),
      builder: (_) {
        final now = vm.messagesOf(_id).firstWhere((x) => x.id == m.id, orElse: () => m);
        if (now.hidden) {
          final waiting = now.reveal == 'req';
          return HiddenMessageBubble(
            senderName: name,
            label: waiting
                ? 'Mensagem oculta. Pedido enviado: aguardando ${vm.nameOf(now.senderUid)} aprovar'
                : now.reveal == 'den'
                ? 'Mensagem oculta. ${vm.nameOf(now.senderUid)} não permitiu. Toque para pedir de novo'
                : 'Mensagem oculta. Toque para pedir a ${vm.nameOf(now.senderUid)} que mostre de novo',
            onTap: waiting ? null : () => vm.messaging.requestReveal(_id, m.id),
          );
        }
        return MessageBubbleWidget(
          message: now,
          isMe: now.outgoing,
          senderName: name,
          onDelete: () => vm.messaging.deleteMessage(_id, m.id),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ConversationsViewModel>();
    final c = vm.byId(_id);
    final messages = vm.messagesOf(_id);
    if (messages.length != _lastCount) {
      _lastCount = messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // What is on screen counts as shown: its visibility window starts now.
        if (mounted) vm.messaging.markViewed(_id);
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final isGroup = c?.type == ConversationType.group;
    final ended = c?.ended ?? false;
    final ready = c != null && !c.pendingWelcome && !ended;
    final canSetWindow = c != null && !ended && !c.pendingWelcome;
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
          if (canSetWindow)
            IconButton(
              icon: Icon(c.visibilityWindow == null ? Icons.visibility_outlined : Icons.timer_outlined),
              tooltip: 'Tempo de visualização',
              onPressed: () => _pickWindow(vm, c.visibilityWindow),
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
          if (c != null && !ended) ..._pending(vm, c),
          if (ended)
            const MaterialBanner(
              content: Text('Você não faz mais parte desta conversa. O histórico continua aqui até você apagar.'),
              leading: Icon(Icons.info_outline),
              actions: [SizedBox.shrink()],
            ),
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
                    itemBuilder: (context, i) => _message(vm, c, messages[i], isGroup),
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
                        hintText: ended ? 'Conversa encerrada' : 'Mensagem',
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
