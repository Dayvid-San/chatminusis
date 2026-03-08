import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../view_models/chat_view_model.dart';
import '../../auth/view_models/auth_view_model.dart';
import '../widgets/message_bubble_widget.dart';

class ChatRoomView extends StatefulWidget {
  const ChatRoomView({super.key});

  @override
  State<ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<ChatRoomView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Listen to changes in the view model to trigger the auto-scroll
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chatViewModel = context.read<ChatViewModel>();
      chatViewModel.addListener(_scrollToBottom);
    });
  }

  @override
  void dispose() {
    // Stop listening to the view model to prevent memory leaks
    final chatViewModel = context.read<ChatViewModel>();
    chatViewModel.removeListener(_scrollToBottom);
    
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Automatically scrolls to the end of the list when new messages arrive
  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  /// Handles the logic for sending a message using the Auth and Chat ViewModels
  void _handleSendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final authViewModel = context.read<AuthViewModel>();
    final chatViewModel = context.read<ChatViewModel>();
    final currentUser = authViewModel.currentUser;

    if (currentUser != null) {
      // Extracts username from email (e.g., "dev@flugo.com" -> "dev")
      final userName = currentUser.email?.split('@').first ?? 'Anonymous';
      
      // FIXED: Calling with Named Parameters
      chatViewModel.sendMessage(
        text: text,
        userId: currentUser.uid,
        userName: userName,
      );
      
      _messageController.clear();
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatViewModel = context.watch<ChatViewModel>();
    final authViewModel = context.read<AuthViewModel>();
    final currentUser = authViewModel.currentUser;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Flugo Real-time Chat'),
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
          // Message List Area
          Expanded(
            child: chatViewModel.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 10),
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
          
          // Input Area
          _buildMessageInput(),
        ],
      ),
    );
  }

  /// Builds the bottom text input and send button
  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, -3),
            blurRadius: 6,
            color: Colors.black.withOpacity(0.05),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Write a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey[200],
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _handleSendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _handleSendMessage,
              child: CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(context).primaryColor,
                child: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}