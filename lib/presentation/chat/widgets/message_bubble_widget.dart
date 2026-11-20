import 'package:chatminusis_components/chatminusis_components.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/entities/conversation.dart';

/// Adapts a [DecryptedMessage] to the generic [MessageBubble].
class MessageBubbleWidget extends StatelessWidget {
  final DecryptedMessage message;
  final bool isMe;

  /// Shown above messages from other people (group chats).
  final String? senderName;

  /// Deletes this message from THIS device only (the server holds nothing).
  final VoidCallback? onDelete;

  const MessageBubbleWidget({super.key, required this.message, required this.isMe, this.senderName, this.onDelete});

  @override
  Widget build(BuildContext context) => MessageBubble(
    text: message.text,
    timeLabel: DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(message.timestamp)),
    isMine: isMe,
    senderName: senderName,
    onDelete: onDelete,
    hasMenu: message.senderUid.isNotEmpty,
  );
}
