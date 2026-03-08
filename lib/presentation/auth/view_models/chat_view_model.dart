import 'package:flutter/material.dart';
import '../../../data/models/chat_message_model.dart';
import '../../../data/services/chat_service.dart';

class ChatViewModel extends ChangeNotifier {
  final ChatService _chatService;
  
  List<ChatMessage> _messages = [];
  bool _isLoading = true;

  ChatViewModel(this._chatService) {
    _initMessageStream();
  }

  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;

  void _initMessageStream() {
    _chatService.getMessagesStream().listen((messageList) {
      _messages = messageList;
      _isLoading = false;
      notifyListeners(); 
    }, onError: (error) {
      _isLoading = false;
      notifyListeners();
    });
  }

  Future<void> sendMessage(String text, String userId, String userName) async {
    if (text.trim().isEmpty) return;

    try {
      await _chatService.sendMessage(
        text: text.trim(),
        userId: userId,
        userName: userName,
      );
    } catch (e) {
      debugPrint('Error sending message: $e');
    }
  }
}