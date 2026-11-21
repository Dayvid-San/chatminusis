import 'package:flutter/services.dart';

/// The only place that writes to the system clipboard, and only when the user
/// explicitly chooses "Copy" on a message.
///
/// Natively it avoids what a plain copy would leak:
/// - iOS: the item is local-only (not shared to the user's other devices through
///   Universal Clipboard) and expires after a minute;
/// - Android 13+: the item is flagged sensitive, so the system does not show its
///   text in the clipboard preview.
/// Where the native side is missing (tests, other platforms) it falls back to a
/// normal copy.
abstract final class PrivateClipboard {
  static const channel = MethodChannel('chatminusis/private_clipboard');

  static Future<void> copy(String text) async {
    try {
      await channel.invokeMethod<void>('copy', {'text': text});
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}
