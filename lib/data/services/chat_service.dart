import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import '../models/chat_message_model.dart';

class ChatService {
  // Reference to the 'messages' node in the Realtime Database
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref().child('messages');

  /// Pushes a new message to the database.
  /// Using push() ensures each message gets a unique, time-ordered ID.
  Future<void> sendMessage({
    required String text,
    required String userId,
    required String userName,
  }) async {
    try {
      final Map<String, dynamic> messageData = {
        'senderId': userId,
        'senderName': userName,
        'text': text,
        'timestamp': ServerValue.timestamp, // Server-side time prevents local clock issues
      };

      await _dbRef
          .push()
          .set(messageData)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw Exception(
        'Connection timed out. Verify that Firebase Realtime Database is configured correctly.',
      );
    } catch (e) {
      throw Exception('Database Error: $e');
    }
  }

  /// Returns a real-time Stream of message lists.
  /// It automatically converts Firebase snapshots into ChatMessage objects.
  Stream<List<ChatMessage>> getMessagesStream() {
    return _dbRef.onValue.map((event) {
      final Map<dynamic, dynamic>? data = event.snapshot.value as Map?;
      
      if (data == null) return [];

      // Convert the Map entries into a List of ChatMessage objects
      final List<ChatMessage> messages = data.entries.map((entry) {
        final String key = entry.key as String;
        final Map<dynamic, dynamic> value = entry.value as Map;
        return ChatMessage.fromMap(key, value);
      }).toList();

      // Sort messages chronologically by timestamp
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      return messages;
    });
  }
}