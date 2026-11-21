import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/presentation/message_bubble_widget.dart';

DecryptedMessage msg(String text, DateTime at, {bool outgoing = false}) => DecryptedMessage(
  id: '1',
  conversationId: 'c',
  senderUid: outgoing ? 'me' : 'bob',
  text: text,
  timestamp: at.millisecondsSinceEpoch,
  outgoing: outgoing,
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

  testWidgets('group message shows the sender name', (tester) async {
    await pump(
      tester,
      MessageBubbleWidget(message: msg('Oi', DateTime(2026, 3, 9, 9, 15)), isMe: false, senderName: 'Bob'),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('09:15'), findsOneWidget);
  });

  testWidgets('direct message from the other person has no name label', (tester) async {
    await pump(tester, MessageBubbleWidget(message: msg('Oi', DateTime(2026, 3, 9, 9, 15)), isMe: false));
    expect(find.text('Oi'), findsOneWidget);
    expect(find.text('Você'), findsNothing);
  });
}
