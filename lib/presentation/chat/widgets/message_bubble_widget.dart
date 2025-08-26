import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../data/models/chat_message_model.dart';

class MessageBubbleWidget extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;

  const MessageBubbleWidget({
    super.key,
    required this.message,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final formattedTime = DateFormat(
      'HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(message.timestamp));
    final bubbleColor = isMe
        ? const Color(0xFF111111)
        : const Color(0xFFF1F3F5);
    final textColor = isMe ? Colors.white : const Color(0xFF111111);
    final timeColor = isMe ? Colors.white70 : const Color(0xFF6B7280);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: isMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
            child: Text(
              isMe ? 'You' : message.senderName,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
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
                Text(
                  message.text,
                  style: TextStyle(color: textColor, fontSize: 15, height: 1.3),
                ),
                const SizedBox(height: 3),
                Text(
                  formattedTime,
                  style: TextStyle(color: timeColor, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
