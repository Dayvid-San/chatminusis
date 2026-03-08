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
    // Formatting the timestamp to a readable time (e.g., 14:30)
    final String formattedTime = DateFormat('HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(message.timestamp),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: Column(
        // Aligns to the right if isMe is true, left otherwise
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Sender Name
          Padding(
            padding: const EdgeInsets.only(bottom: 2.0, left: 4.0, right: 4.0),
            child: Text(
              isMe ? 'You' : message.senderName,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          
          // Message Container
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            decoration: BoxDecoration(
              color: isMe ? Colors.blue[700] : Colors.grey[300],
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16.0),
                topRight: const Radius.circular(16.0),
                bottomLeft: Radius.circular(isMe ? 16.0 : 0),
                bottomRight: Radius.circular(isMe ? 0 : 16.0),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  message.text,
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black87,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formattedTime,
                  style: TextStyle(
                    color: isMe ? Colors.white70 : Colors.black54,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}