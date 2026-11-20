import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/core/security/private_clipboard.dart';
import 'package:myapp/domain/entities/conversation.dart';
import 'package:myapp/presentation/chat/widgets/message_bubble_widget.dart';
import 'package:myapp/presentation/shared_widgets/private_input.dart';

ContextMenuButtonItem item(ContextMenuButtonType type) => ContextMenuButtonItem(type: type, onPressed: () {});

DecryptedMessage message(String text, {String sender = 'bob'}) => DecryptedMessage(
  id: 'm1',
  conversationId: 'c',
  senderUid: sender,
  text: text,
  timestamp: DateTime(2026, 11, 20, 9).millisecondsSinceEpoch,
  outgoing: false,
);

Future<void> pumpBubble(WidgetTester tester, DecryptedMessage m, {VoidCallback? onDelete}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: MessageBubbleWidget(message: m, isMe: false, onDelete: onDelete),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('private text input', () {
    test('the selection menu keeps only editing actions', () {
      final kept = PrivateInput.filterMenu([
        for (final t in ContextMenuButtonType.values) item(t),
      ]).map((i) => i.type).toSet();
      expect(kept, {
        ContextMenuButtonType.cut,
        ContextMenuButtonType.copy,
        ContextMenuButtonType.paste,
        ContextMenuButtonType.selectAll,
      });
      for (final removed in [
        ContextMenuButtonType.share,
        ContextMenuButtonType.lookUp,
        ContextMenuButtonType.searchWeb,
        ContextMenuButtonType.liveTextInput,
        ContextMenuButtonType.custom,
      ]) {
        expect(kept.contains(removed), isFalse, reason: '$removed must not be offered');
      }
    });

    testWidgets('PrivateTextField turns off everything that would hand the text to other apps', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PrivateTextField())));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse, reason: 'the keyboard must not learn from messages');
      expect(field.spellCheckConfiguration!.spellCheckEnabled, isFalse);
      expect(field.autofillHints, isEmpty, reason: 'no autofill service');
      expect(field.contextMenuBuilder, same(PrivateInput.contextMenu));
    });

    testWidgets('PrivateTextFormField has the same protections', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PrivateTextFormField())));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.spellCheckConfiguration!.spellCheckEnabled, isFalse);
      expect(field.autofillHints, isEmpty);
      expect(field.contextMenuBuilder, same(PrivateInput.contextMenu));
    });
  });

  group('copying a message', () {
    final nativeCalls = <MethodCall>[];
    final systemClipboard = <String>[];

    setUp(() {
      nativeCalls.clear();
      systemClipboard.clear();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') systemClipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
    });

    tearDown(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PrivateClipboard.channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    void withNativeSide() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PrivateClipboard.channel,
      (call) async {
        nativeCalls.add(call);
        return null;
      },
    );

    test('goes through the native private copy (local-only on iOS, sensitive on Android)', () async {
      withNativeSide();
      await PrivateClipboard.copy('segredo');
      expect(nativeCalls.single.method, 'copy');
      expect((nativeCalls.single.arguments as Map)['text'], 'segredo');
      expect(systemClipboard, isEmpty, reason: 'the plain system copy must not run as well');
    });

    test('falls back to a normal copy only where the native side is missing', () async {
      await PrivateClipboard.copy('segredo'); // no handler: MissingPluginException
      expect(systemClipboard, ['segredo']);
    });

    test('falls back if the native copy fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PrivateClipboard.channel,
        (call) async => throw PlatformException(code: 'boom'),
      );
      await PrivateClipboard.copy('segredo');
      expect(systemClipboard, ['segredo']);
    });

    testWidgets('nothing is copied unless the user holds the message and chooses Copy', (tester) async {
      withNativeSide();
      await pumpBubble(tester, message('olá, tudo bem?'));
      await tester.tap(find.text('olá, tudo bem?'));
      await tester.pumpAndSettle();
      expect(find.text('Copiar mensagem'), findsNothing, reason: 'a tap does nothing');
      expect(nativeCalls, isEmpty);

      await tester.longPress(find.text('olá, tudo bem?'));
      await tester.pumpAndSettle();
      expect(find.text('Copiar mensagem'), findsOneWidget);
      expect(nativeCalls, isEmpty, reason: 'opening the menu still copies nothing');

      await tester.tap(find.text('Copiar mensagem'));
      await tester.pumpAndSettle();
      expect((nativeCalls.single.arguments as Map)['text'], 'olá, tudo bem?');
    });

    testWidgets('dismissing the menu copies nothing', (tester) async {
      withNativeSide();
      await pumpBubble(tester, message('não copie'));
      await tester.longPress(find.text('não copie'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5)); // outside the sheet
      await tester.pumpAndSettle();
      expect(nativeCalls, isEmpty);
      expect(systemClipboard, isEmpty);
    });

    testWidgets('the delete option exists only when deleting is wired, and says it is local', (tester) async {
      await pumpBubble(tester, message('oi'));
      await tester.longPress(find.text('oi'));
      await tester.pumpAndSettle();
      expect(find.text('Apagar neste aparelho'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      var deleted = 0;
      await pumpBubble(tester, message('oi'), onDelete: () => deleted++);
      await tester.longPress(find.text('oi'));
      await tester.pumpAndSettle();
      expect(find.text('Não existe cópia em nenhum outro lugar.'), findsOneWidget);
      await tester.tap(find.text('Apagar neste aparelho'));
      await tester.pumpAndSettle();
      expect(deleted, 1);
    });

    testWidgets('system notices (no sender) have no menu at all', (tester) async {
      withNativeSide();
      await pumpBubble(tester, message('A chave de segurança mudou.', sender: ''));
      await tester.longPress(find.text('A chave de segurança mudou.'));
      await tester.pumpAndSettle();
      expect(find.text('Copiar mensagem'), findsNothing);
    });
  });
}
