/// A chat message already decrypted (or, for the legacy room, plain).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String text;

  /// Milliseconds since epoch.
  final int timestamp;

  bool get isValid => text.trim().isNotEmpty;
}
