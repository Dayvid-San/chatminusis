// Unit tests of the pieces MessagingService is built from. They need no crypto
// library and no server.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/domain/conversation_state.dart';
import 'package:myapp/features/messaging/domain/identity_pins.dart';
import 'package:myapp/features/messaging/domain/serial_queue.dart';
import 'package:myapp/features/messaging/domain/visibility_policy.dart';

import '../fakes/memory_secure_store.dart';

DecryptedMessage msg(String id, {bool outgoing = false, String sender = 'bob', int? viewedUntil}) => DecryptedMessage(
  id: id,
  conversationId: 'c',
  senderUid: sender,
  text: 'texto $id',
  timestamp: 1,
  outgoing: outgoing,
  viewedUntil: viewedUntil,
);

ConversationState conv({int window = 60}) => ConversationState(id: 'c', type: ConversationType.direct)
  ..visibilitySeconds = window
  ..messages.addAll([msg('in'), msg('out', outgoing: true, sender: 'me'), msg('sys', sender: '')]);

void main() {
  group('VisibilityPolicy', () {
    test('only received messages ever hide; own and system notices never do', () {
      final c = conv();
      VisibilityPolicy.startForUnseen(c, 0);
      for (final m in c.messages) {
        final seen = VisibilityPolicy.view(c, m, 1000000);
        expect(seen.hidden, m.id == 'in');
      }
    });

    test('a message that was never shown is not hidden, however long it waited', () {
      final c = conv();
      expect(VisibilityPolicy.view(c, c.messages.first, 99999999).hidden, isFalse);
    });

    test('hides exactly when the window ends, without its text, and keeps the stored text', () {
      final c = conv();
      VisibilityPolicy.startForUnseen(c, 1000); // window 60 s -> until 61000
      expect(VisibilityPolicy.view(c, c.messages.first, 60999).hidden, isFalse);
      final hidden = VisibilityPolicy.view(c, c.messages.first, 61000);
      expect(hidden.hidden, isTrue);
      expect(hidden.text, isEmpty);
      expect(c.messages.first.text, 'texto in', reason: 'stored text is untouched');
    });

    test('window 0 shows everything', () {
      final c = conv(window: 0);
      c.messages[0] = msg('in', viewedUntil: 1);
      expect(VisibilityPolicy.view(c, c.messages.first, 999).hidden, isFalse);
    });

    test('startForUnseen does not restart messages already shown', () {
      final c = conv();
      c.messages[0] = msg('in', viewedUntil: 5000);
      expect(VisibilityPolicy.startForUnseen(c, 100000), isFalse);
      expect(c.messages.first.viewedUntil, 5000);
    });

    test('reveal restarts one received message, and refuses own and unknown ones', () {
      final c = conv();
      c.messages[0] = msg('in', viewedUntil: 5000);
      expect(VisibilityPolicy.reveal(c, 'in', 10000), isTrue);
      expect(c.messages.first.viewedUntil, 70000);
      expect(VisibilityPolicy.reveal(c, 'out', 10000), isFalse);
      expect(VisibilityPolicy.reveal(c, 'sys', 10000), isFalse);
      expect(VisibilityPolicy.reveal(c, 'nope', 10000), isFalse);
    });

    test('turning the window on covers what is stored; changing it does not restart anything', () {
      final c = conv(window: 0);
      VisibilityPolicy.apply(c, 30, 1000);
      expect(c.messages.first.viewedUntil, 31000);
      VisibilityPolicy.apply(c, 90, 50000);
      expect(c.messages.first.viewedUntil, 31000);
    });
  });

  group('IdentityPins', () {
    test('first sight pins, a different key flags a change, verifying accepts it', () async {
      final pins = IdentityPins(MemorySecureStore());
      expect(pins.statusOf('bob'), KeyStatus.unknown);
      expect(pins.observe('bob', 'A'), PinObservation.pinned);
      expect(pins.statusOf('bob'), KeyStatus.pinned);
      expect(pins.observe('bob', 'A'), PinObservation.unchanged);
      expect(pins.observe('bob', 'B'), PinObservation.changed);
      expect(pins.statusOf('bob'), KeyStatus.changed);
      expect(pins.currentKey('bob'), 'B');
      expect(pins.observe('bob', 'B'), PinObservation.unchanged, reason: 'the same change is reported once');
      expect(pins.markVerified('bob'), isTrue);
      expect(pins.statusOf('bob'), KeyStatus.verified);
      expect(pins.markVerified('nobody'), isFalse);
    });

    test('survives a restart', () async {
      final store = MemorySecureStore();
      final a = IdentityPins(store)..observe('bob', 'A');
      a.markVerified('bob');
      await a.save();
      final b = IdentityPins(store);
      await b.load();
      expect(b.statusOf('bob'), KeyStatus.verified);
    });
  });

  group('ConversationStore', () {
    test('saves, reloads and removes', () async {
      final vault = MemorySecureStore();
      final store = ConversationStore(vault);
      await store.save(conv()..title = 'x');
      final again = ConversationStore(vault);
      await again.load();
      expect(again.all['c']!.title, 'x');
      expect(again.all['c']!.messages.length, 3);
      expect(again.all['c']!.visibilitySeconds, 60);
      await again.remove('c');
      final third = ConversationStore(vault);
      await third.load();
      expect(third.all, isEmpty);
    });
  });

  test('SerialQueue runs jobs one at a time, in order, and survives a failing job', () async {
    final q = SerialQueue();
    final log = <String>[];
    final a = q.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      log.add('a');
    });
    final bad = q.run<void>(() async => throw StateError('x'));
    final c = q.run(() async => log.add('c'));
    await expectLater(bad, throwsStateError);
    await Future.wait([a, c]);
    expect(log, ['a', 'c']);
  });
}
