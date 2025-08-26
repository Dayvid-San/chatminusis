import 'package:flutter/material.dart';
import 'package:myapp/presentation/chat/view_models/chat_view_model.dart';
import 'package:provider/provider.dart';
import '../auth/view_models/auth_view_model.dart';
import 'widgets/message_bubble_widget.dart';

class ChatRoomView extends StatefulWidget {
  const ChatRoomView({super.key});

  @override
  State<ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<ChatRoomView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final ChatViewModel _chatViewModel;
  int _lastScrollRequest = 0;
  int _lastErrorRequest = 0;

  @override
  void initState() {
    super.initState();
    _chatViewModel = context.read<ChatViewModel>();
    _lastScrollRequest = _chatViewModel.scrollRequest;
    _lastErrorRequest = _chatViewModel.errorRequest;
    _chatViewModel.addListener(_handleViewModelChange);
  }

  @override
  void dispose() {
    _chatViewModel.removeListener(_handleViewModelChange);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleViewModelChange() {
    if (_lastErrorRequest != _chatViewModel.errorRequest) {
      _lastErrorRequest = _chatViewModel.errorRequest;
      _showChatError();
    }

    if (_lastScrollRequest != _chatViewModel.scrollRequest) {
      _lastScrollRequest = _chatViewModel.scrollRequest;
      _scheduleScrollToBottom();
    }
  }

  void _showChatError() {
    final message = _chatViewModel.errorMessage;
    if (message.isEmpty || !mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _handleSendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final authViewModel = context.read<AuthViewModel>();
    final chatViewModel = context.read<ChatViewModel>();
    final currentUser = authViewModel.currentUser;

    if (currentUser != null) {
      final userName = currentUser.email?.split('@').first ?? 'Anonymous';

      final didSend = await chatViewModel.sendMessage(
        text: text,
        userId: currentUser.uid,
        userName: userName,
      );

      if (didSend && mounted) {
        _messageController.clear();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatViewModel = context.watch<ChatViewModel>();
    final authViewModel = context.read<AuthViewModel>();
    final currentUser = authViewModel.currentUser;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          title: const Text('Flugo Chat'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => authViewModel.signOut(),
              tooltip: 'Logout',
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: chatViewModel.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : chatViewModel.messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          chatViewModel.errorMessage.isNotEmpty
                              ? chatViewModel.errorMessage
                              : 'No messages yet. Start the conversation.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      itemCount: chatViewModel.messages.length,
                      itemBuilder: (context, index) {
                        final message = chatViewModel.messages[index];
                        final isMe = message.senderId == currentUser?.uid;

                        return MessageBubbleWidget(
                          message: message,
                          isMe: isMe,
                        );
                      },
                    ),
            ),
            _buildMessageInput(
              bottomInset,
              isSending: chatViewModel.isSending,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageInput(double bottomInset, {required bool isSending}) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset > 0 ? 8 : 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                textInputAction: TextInputAction.send,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(18)),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Color(0xFFF1F3F5),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                onTap: _scheduleScrollToBottom,
                onChanged: (_) {
                  if (_chatViewModel.errorMessage.isNotEmpty) {
                    _chatViewModel.clearError();
                  }
                },
                onSubmitted: (_) async => _handleSendMessage(),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 42,
              width: 42,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Color(0xFF111111),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                  onPressed: isSending ? null : _handleSendMessage,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
