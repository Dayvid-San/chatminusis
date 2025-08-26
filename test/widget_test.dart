import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/data/models/chat_message_model.dart';
import 'package:myapp/presentation/chat/widgets/message_bubble_widget.dart';

void main() {
  testWidgets('Message bubble renders current user message details', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      id: '1',
      senderId: 'user-1',
      senderName: 'alice',
      text: 'Hello world',
      timestamp: DateTime(2026, 3, 9, 14, 30).millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubbleWidget(message: message, isMe: true)),
      ),
    );

    expect(find.text('You'), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    expect(find.text('14:30'), findsOneWidget);
  });

  testWidgets('Message bubble renders sender name for other users', (
    WidgetTester tester,
  ) async {
    final message = ChatMessage(
      id: '2',
      senderId: 'user-2',
      senderName: 'bob',
      text: 'Hi there',
      timestamp: DateTime(2026, 3, 9, 9, 15).millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubbleWidget(message: message, isMe: false),
        ),
      ),
    );

    expect(find.text('bob'), findsOneWidget);
    expect(find.text('Hi there'), findsOneWidget);
    expect(find.text('09:15'), findsOneWidget);
  });
}
