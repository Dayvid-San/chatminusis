import 'package:flutter/material.dart';

import '../privacy/private_clipboard.dart';

/// A chat bubble. Generic: it receives strings and callbacks, not domain types.
///
/// Holding the bubble opens a menu with "Copy" (the only way a message leaves
/// the app, through [PrivateClipboard]) and, when [onDelete] is given, "Delete".
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.timeLabel,
    required this.isMine,
    this.senderName,
    this.onDelete,
    this.hasMenu = true,
  });

  final String text;
  final String timeLabel;
  final bool isMine;

  /// Shown above messages from other people (group chats).
  final String? senderName;

  /// Deletes the message on THIS device only (the server holds nothing).
  final VoidCallback? onDelete;

  /// False for system notices, which can not be copied or deleted.
  final bool hasMenu;

  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<_Action>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copiar mensagem'),
              onTap: () => Navigator.pop(sheet, _Action.copy),
            ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Apagar neste aparelho'),
                subtitle: const Text('Não existe cópia em nenhum outro lugar.'),
                onTap: () => Navigator.pop(sheet, _Action.delete),
              ),
          ],
        ),
      ),
    );
    switch (action) {
      case _Action.copy:
        await PrivateClipboard.copy(text);
      case _Action.delete:
        onDelete?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => BubbleFrame(
    isMine: isMine,
    senderName: senderName,
    onLongPress: hasMenu ? () => _showActions(context) : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(text, style: TextStyle(color: isMine ? Colors.white : const Color(0xFF111111), fontSize: 15, height: 1.3)),
        const SizedBox(height: 3),
        Text(timeLabel, style: TextStyle(color: isMine ? Colors.white70 : const Color(0xFF6B7280), fontSize: 10)),
      ],
    ),
  );
}

/// The bubble shape, name label and alignment shared by every kind of bubble.
class BubbleFrame extends StatelessWidget {
  const BubbleFrame({super.key, required this.isMine, required this.child, this.senderName, this.onLongPress, this.onTap});

  final bool isMine;
  final String? senderName;
  final Widget child;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Column(
      crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (isMine || senderName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
            child: Text(
              isMine ? 'Você' : senderName!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280), fontWeight: FontWeight.w500),
            ),
          ),
        GestureDetector(
          onLongPress: onLongPress,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            decoration: BoxDecoration(
              color: isMine ? const Color(0xFF111111) : const Color(0xFFF1F3F5),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMine ? 16 : 4),
                bottomRight: Radius.circular(isMine ? 4 : 16),
              ),
            ),
            child: child,
          ),
        ),
      ],
    ),
  );
}

enum _Action { copy, delete }
