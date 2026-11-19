import '../entities/chat_message.dart';

/// Legacy single public room (plain text). Replaced by encrypted
/// conversations in stage 4; kept read-only afterwards.
abstract class GlobalChatRepository {
  Stream<List<ChatMessage>> watchMessages();
  Future<void> sendMessage({required String text, required String userId, required String userName});
}
