import 'package:flutter/material.dart';

import 'message_bubble.dart';

/// Placeholder for a message that is no longer visible. Shows no text; tapping
/// it asks to see the message again.
class HiddenMessageBubble extends StatelessWidget {
  const HiddenMessageBubble({super.key, required this.onReveal, this.senderName, this.revealFor});

  final VoidCallback onReveal;
  final String? senderName;

  /// How long it stays visible after being revealed, e.g. "30 s".
  final String? revealFor;

  @override
  Widget build(BuildContext context) => BubbleFrame(
    isMine: false,
    senderName: senderName,
    onTap: onReveal,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.visibility_off_outlined, size: 16, color: Color(0xFF6B7280)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            revealFor == null ? 'Mensagem oculta. Toque para ver de novo' : 'Mensagem oculta. Toque para ver por $revealFor',
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ),
      ],
    ),
  );
}
