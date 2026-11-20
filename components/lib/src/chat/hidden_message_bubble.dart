import 'package:flutter/material.dart';

import 'message_bubble.dart';

/// Placeholder for a message that is no longer visible. Shows no text, only
/// [label] (say what happens next). Tapping it calls [onTap], if given.
class HiddenMessageBubble extends StatelessWidget {
  const HiddenMessageBubble({super.key, required this.label, this.onTap, this.senderName});

  final String label;
  final VoidCallback? onTap;
  final String? senderName;

  @override
  Widget build(BuildContext context) => BubbleFrame(
    isMine: false,
    senderName: senderName,
    onTap: onTap,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.visibility_off_outlined, size: 16, color: Color(0xFF6B7280)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ),
      ],
    ),
  );
}
