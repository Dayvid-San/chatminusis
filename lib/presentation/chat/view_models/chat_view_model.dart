import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/chat_message_model.dart';
import '../../../data/services/chat_service.dart';

class ChatViewModel extends ChangeNotifier {
  final ChatService _chatService;
  
  // Internal state variables
  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  String _errorMessage = '';
  StreamSubscription<List<ChatMessage>>? _messageSubscription;

  ChatViewModel(this._chatService) {
    _startListeningToMessages();
  }

  // Public getters to expose the state safely to the UI
  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;

  /// Subscribes to the real-time Stream provided by the ChatService.
  void _startListeningToMessages() {
    _messageSubscription = _chatService.getMessagesStream().listen(
      (newMessageList) {
        _messages = newMessageList;
        _isLoading = false;
        _errorMessage = '';
        notifyListeners(); // Rebuilds the UI with new data
      },
      onError: (error) {
        _isLoading = false;
        _errorMessage = 'Error loading messages: $error';
        notifyListeners();
      },
    );
  }

  /// Sends a message and handles potential errors.
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
      // We don't need to manually update the list here because 
      // the Stream listener above will detect the new database entry.
    } catch (e) {
      _errorMessage = 'Failed to send message: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    // Crucial to prevent memory leaks when the user logs out
    _messageSubscription?.cancel();
    super.dispose();
  }
}