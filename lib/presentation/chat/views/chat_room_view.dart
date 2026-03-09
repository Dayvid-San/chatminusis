import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../auth/view_models/auth_view_model.dart';
import '../view_models/chat_view_model.dart'; // Certifique-se que o ViewModel usa o seu ChatMessage
import '../../../data/models/chat_message.dart';

class ChatRoomView extends StatefulWidget {
  const ChatRoomView({super.key});

  @override
  State<ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<ChatRoomView> {
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();
    final chatViewModel = context.watch<ChatViewModel>();
    final currentUser = authViewModel.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Flugo Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => authViewModel.signOut(),
          ),
        ],
      ),
      body: Column(
        children: [
          // LISTA DE MENSAGENS EM TEMPO REAL
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: chatViewModel.messagesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final messages = snapshot.data ?? [];
                
                // Auto-scroll sempre que uma nova mensagem chegar
                WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final isMe = msg.senderId == currentUser?.uid;

                    return _buildMessageBubble(msg, isMe);
                  },
                );
              },
            ),
          ),
          
          // CAMPO DE TEXTO E BOTÃO DE ENVIO
          _buildMessageInput(chatViewModel, currentUser),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMe ? Colors.green[100] : Colors.grey[200], // Diferenciação visual
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMe) Text(msg.senderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Text(msg.text),
            Text(
              TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(msg.timestamp)).format(context),
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageInput(ChatViewModel vm, dynamic user) {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: vm.messageController,
              decoration: const InputDecoration(hintText: 'Digite sua mensagem...'),
              onSubmitted: (_) => vm.sendMessage(user?.uid ?? '', user?.displayName ?? 'User'),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Colors.green),
            onPressed: () => vm.sendMessage(user?.uid ?? '', user?.displayName ?? 'User'), // Envio funcional
          ),
        ],
      ),
    );
  }
}
