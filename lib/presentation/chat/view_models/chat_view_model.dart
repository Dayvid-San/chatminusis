import 'dart:async';
import 'package:flutter/material.dart';
import '../../../domain/entities/chat_message.dart';
import '../../../domain/repositories/global_chat_repository.dart';

class ChatViewModel extends ChangeNotifier {
  final GlobalChatRepository _chatService;

  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  bool _isSending = false;
  String _errorMessage = '';
  int _scrollRequest = 0;
  int _errorRequest = 0;
  StreamSubscription<List<ChatMessage>>? _messageSubscription;
  Timer? _initialLoadTimeout;

  ChatViewModel(this._chatService) {
    _startListeningToMessages();
  }

  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;
  String get errorMessage => _errorMessage;
  int get scrollRequest => _scrollRequest;
  int get errorRequest => _errorRequest;

  void clearError() {
    if (_errorMessage.isEmpty) {
      return;
    }

    _errorMessage = '';
    notifyListeners();
  }

  void _startListeningToMessages() {
    _initialLoadTimeout?.cancel();
    _initialLoadTimeout = Timer(const Duration(seconds: 10), () {
      if (!_isLoading) {
        return;
      }

      _isLoading = false;
      _errorMessage =
          'Não foi possível carregar as mensagens.';
      _errorRequest++;
      notifyListeners();
    });

    _messageSubscription = _chatService.watchMessages().listen(
      (newMessageList) {
        _initialLoadTimeout?.cancel();
        final wasLoading = _isLoading;
        final previousLastMessageId = _messages.isEmpty
            ? null
            : _messages.last.id;
        final nextLastMessageId = newMessageList.isEmpty
            ? null
            : newMessageList.last.id;

        _messages = newMessageList;
        _isLoading = false;
        _errorMessage = '';

        if (wasLoading || previousLastMessageId != nextLastMessageId) {
          _scrollRequest++;
        }

        notifyListeners();
      },
      onError: (error) {
        _initialLoadTimeout?.cancel();
        _isLoading = false;
        _errorMessage = 'Erro ao carregar mensagens.';
        _errorRequest++;
        notifyListeners();
      },
    );
  }

  Future<bool> sendMessage({
    required String text,
    required String userId,
    required String userName,
  }) async {
    if (text.trim().isEmpty || _isSending) {
      return false;
    }

    try {
      _isSending = true;
      notifyListeners();

      await _chatService.sendMessage(
        text: text.trim(),
        userId: userId,
        userName: userName,
      );
      _isSending = false;
      notifyListeners();
      return true;
    } catch (e) {
      _isSending = false;
      _errorMessage = 'Falha ao enviar a mensagem.';
      _errorRequest++;
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _initialLoadTimeout?.cancel();
    _messageSubscription?.cancel();
    super.dispose();
  }
}
