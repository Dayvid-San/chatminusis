import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/repositories/global_chat_repository.dart';

class FirebaseGlobalChatRepository implements GlobalChatRepository {
  FirebaseGlobalChatRepository(FirebaseDatabase db) : _ref = db.ref('messages');

  final DatabaseReference _ref;

  @override
  Future<void> sendMessage({required String text, required String userId, required String userName}) async {
    try {
      await _ref
          .push()
          .set({'senderId': userId, 'senderName': userName, 'text': text, 'timestamp': ServerValue.timestamp})
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw Exception('Tempo esgotado. Verifique sua conexão.');
    }
  }

  @override
  Stream<List<ChatMessage>> watchMessages() {
    return _ref.orderByChild('timestamp').limitToLast(200).onValue.map((event) {
      final data = event.snapshot.value;
      if (data is! Map) return <ChatMessage>[];
      final messages = <ChatMessage>[];
      data.forEach((key, value) {
        if (value is! Map) return;
        messages.add(
          ChatMessage(
            id: key as String,
            senderId: value['senderId'] as String? ?? '',
            senderName: value['senderName'] as String? ?? 'Anônimo',
            text: value['text'] as String? ?? '',
            timestamp: value['timestamp'] as int? ?? 0,
          ),
        );
      });
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return messages;
    });
  }
}
