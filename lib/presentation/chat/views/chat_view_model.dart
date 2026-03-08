import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/chat_message_model.dart';
import '../../../data/services/chat_service.dart';

class ChatViewModel extends ChangeNotifier {
  final ChatService _chatService;
  
  // Internal state
  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  String _errorMessage = '';
  StreamSubscription<List<ChatMessage>>? _messageSubscription;

  ChatViewModel(this._chatService) {
    _startListeningToMessages();
  }

  // Getters to expose state to the UI
  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;

  /// Subscribes to the real-time stream from Firebase.
  /// Updates the message list and notifies listeners automatically.
  void _startListeningToMessages() {
    _messageSubscription = _chatService.getMessagesStream().listen(
      (newMessageList) {
        _messages = newMessageList;
        _isLoading = false;
        _errorMessage = '';
        notifyListeners(); // This triggers the UI to rebuild
      },
      onError: (error) {
        _isLoading = false;
        _errorMessage = 'Error loading messages: $error';
        notifyListeners();
      },
    );
  }

  /// Sends a new message to the global chat.
  Future<void> sendMessage({
    required String text,
    required String userId,
    required String userName,
  }) async {
    if (text.trim().isEmpty) return;

    try {
      await _chatService.sendMessage(
        text: text.trim(),
        userId: userId,
        userName: userName,
      );
      // No need to manually update _messages because the stream listener 
      // will pick up the new database entry and notify automatically.
    } catch (e) {
      _errorMessage = 'Failed to send message.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    // Crucial: Always cancel subscriptions to prevent memory leaks
    _messageSubscription?.cancel();
    super.dispose();
  }
}