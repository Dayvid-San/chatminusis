import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/domain/entities/conversation.dart';
import 'package:myapp/presentation/chat/widgets/message_bubble_widget.dart';

DecryptedMessage msg(String text, DateTime at, {bool outgoing = false, int? expiresAt}) => DecryptedMessage(
  id: '1',
  conversationId: 'c',
  senderUid: outgoing ? 'me' : 'bob',
  text: text,
  timestamp: at.millisecondsSinceEpoch,
  outgoing: outgoing,
  expiresAt: expiresAt,
);

Future<void> pump(WidgetTester tester, Widget w) => tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));

void main() {
  testWidgets('own message shows "Você" and the time', (tester) async {
    await pump(
      tester,
      MessageBubbleWidget(message: msg('Olá', DateTime(2026, 3, 9, 14, 30), outgoing: true), isMe: true),
    );
    expect(find.text('Você'), findsOneWidget);
    expect(find.text('Olá'), findsOneWidget);
    expect(find.text('14:30'), findsOneWidget);
  });

  testWidgets('group message shows the sender name; disappearing ones a timer', (tester) async {
    await pump(
      tester,
      MessageBubbleWidget(
        message: msg('Oi', DateTime(2026, 3, 9, 9, 15), expiresAt: 1),
        isMe: false,
        senderName: 'Bob',
      ),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('⏱ 09:15'), findsOneWidget);
  });

  testWidgets('direct message from the other person has no name label', (tester) async {
    await pump(tester, MessageBubbleWidget(message: msg('Oi', DateTime(2026, 3, 9, 9, 15)), isMe: false));
    expect(find.text('Oi'), findsOneWidget);
    expect(find.text('Você'), findsNothing);
  });
}
