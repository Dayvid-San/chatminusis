import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/security/private_clipboard.dart';
import '../../../domain/entities/conversation.dart';

class MessageBubbleWidget extends StatelessWidget {
  final DecryptedMessage message;
  final bool isMe;

  /// Shown above messages from other people (group chats).
  final String? senderName;

  /// Deletes this message from THIS device only (the server holds nothing).
  final VoidCallback? onDelete;

  const MessageBubbleWidget({super.key, required this.message, required this.isMe, this.senderName, this.onDelete});

  /// The only way a message leaves the app: the user holds it and chooses "Copiar".
  /// (There is no selectable text, no share and no automatic copy.)
  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<_MessageAction>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copiar mensagem'),
              onTap: () => Navigator.pop(sheet, _MessageAction.copy),
            ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Apagar neste aparelho'),
                subtitle: const Text('Não existe cópia em nenhum outro lugar.'),
                onTap: () => Navigator.pop(sheet, _MessageAction.delete),
              ),
          ],
        ),
      ),
    );
    switch (action) {
      case _MessageAction.copy:
        await PrivateClipboard.copy(message.text);
      case _MessageAction.delete:
        onDelete?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final formattedTime = DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(message.timestamp));
    final bubbleColor = isMe ? const Color(0xFF111111) : const Color(0xFFF1F3F5);
    final textColor = isMe ? Colors.white : const Color(0xFF111111);
    final timeColor = isMe ? Colors.white70 : const Color(0xFF6B7280);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isMe || senderName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
              child: Text(
                isMe ? 'Você' : senderName!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280), fontWeight: FontWeight.w500),
              ),
            ),
          GestureDetector(
            onLongPress: message.senderUid.isEmpty ? null : () => _showActions(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(message.text, style: TextStyle(color: textColor, fontSize: 15, height: 1.3)),
                  const SizedBox(height: 3),
                  Text(
                    message.expiresAt == null ? formattedTime : '⏱ $formattedTime',
                    style: TextStyle(color: timeColor, fontSize: 10),
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

enum _MessageAction { copy, delete }
