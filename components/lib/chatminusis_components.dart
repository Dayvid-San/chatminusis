/// Reusable components. Rule: nothing here imports app code (domain, data,
/// services) — only Flutter. Text is passed in as plain strings and actions as
/// callbacks, so any module can use them.
library;

export 'src/chat/hidden_message_bubble.dart';
export 'src/chat/message_bubble.dart';
export 'src/chat/rebuild_at.dart';
export 'src/feedback/confirm_dialog.dart';
export 'src/feedback/duration_label.dart';
export 'src/feedback/empty_state.dart';
export 'src/feedback/error_text.dart';
export 'src/feedback/loading_button.dart';
export 'src/privacy/private_clipboard.dart';
export 'src/privacy/private_input.dart';
