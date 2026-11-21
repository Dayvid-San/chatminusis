import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/domain/conversation_state.dart';

/// The per-conversation visibility rule, in one place and free of I/O.
///
/// A received message is shown until its window runs out, counted from the
/// first time it was displayed (or from the last time the person asked to see
/// it again). Afterwards it is hidden: it keeps being stored, only its text is
/// withheld. Own messages and system notices are never hidden.
abstract final class VisibilityPolicy {
  static bool _counts(DecryptedMessage m) => !m.outgoing && m.senderUid.isNotEmpty;

  /// The message as it may be shown at [nowMs].
  static DecryptedMessage view(ConversationState c, DecryptedMessage m, int nowMs) {
    if (c.visibilitySeconds <= 0 || !_counts(m)) return m;
    final until = m.viewedUntil;
    if (until == null || nowMs < until) return m;
    return m.copyWith(hidden: true, text: '');
  }

  /// The window changed. Turning it on gives what is already stored a window
  /// starting now, so nothing stays visible forever by accident.
  static void apply(ConversationState c, int seconds, int nowMs) {
    final was = c.visibilitySeconds;
    c.visibilitySeconds = seconds;
    if (seconds > 0 && was == 0) startForUnseen(c, nowMs);
  }

  /// Starts the window of received messages never shown before. True if any changed.
  static bool startForUnseen(ConversationState c, int nowMs) {
    if (c.visibilitySeconds <= 0) return false;
    final until = nowMs + c.visibilitySeconds * 1000;
    var changed = false;
    for (var i = 0; i < c.messages.length; i++) {
      final m = c.messages[i];
      if (_counts(m) && m.viewedUntil == null) {
        c.messages[i] = m.copyWith(viewedUntil: until);
        changed = true;
      }
    }
    return changed;
  }

  /// Shows one message again for the window. True if it exists and counts.
  static bool reveal(ConversationState c, String messageId, int nowMs) {
    if (c.visibilitySeconds <= 0) return false;
    final i = c.messages.indexWhere((m) => m.id == messageId);
    if (i < 0 || !_counts(c.messages[i])) return false;
    c.messages[i] = c.messages[i].copyWith(viewedUntil: nowMs + c.visibilitySeconds * 1000, clearReveal: true);
    return true;
  }
}
