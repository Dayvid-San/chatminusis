// End-to-end tests of MessagingService with the REAL Rust/MLS library (via
// FFI) and an in-memory server. Build the library first:
//   cargo build --manifest-path packages/chat_crypto_ffi/rust/Cargo.toml
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/messaging/domain/conversation.dart';
import 'package:myapp/features/messaging/domain/conversation_backend.dart';
import 'package:myapp/features/messaging/domain/messaging_service.dart';

import '../fakes/memory_conversation_backend.dart';
import '../fakes/memory_secure_store.dart';

Future<void> eventually(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met: ${reason ?? ''}');
}

List<String> texts(MessagingService s, String id) => s.messages(id).map((m) => m.text).toList();

void main() {
  setUpAll(() async {
    final ext = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open('packages/chat_crypto_ffi/rust/target/debug/libchat_crypto_ffi.$ext'),
    );
  });

  late MemoryConversationBackend server;
  late DateTime now;
  final services = <MessagingService>[];

  Future<MessagingService> user(String uid, {MemorySecureStore? store}) async {
    final s = MessagingService(
      backend: server,
      store: store ?? MemorySecureStore(),
      uid: uid,
      clock: () => now,
      rejoinDelay: const Duration(milliseconds: 300),
      gapDelay: const Duration(milliseconds: 400),
      repairTakeoverDelay: const Duration(milliseconds: 300),
    );
    await s.start();
    services.add(s);
    return s;
  }

  setUp(() {
    server = MemoryConversationBackend();
    now = DateTime(2026, 11, 19, 12);
  });

  tearDown(() async {
    for (final s in services) {
      await s.dispose();
    }
    services.clear();
  });

  test('publishes identity, key packages and a last-resort package on first start', () async {
    final alice = await user('alice');
    expect(server.identities['alice'], alice.signaturePublicKey);
    expect(server.keyPackages['alice'], hasLength(20));
    expect(server.lastResort['alice'], isNotNull);
  });

  test('1:1 conversation: only ciphertext reaches the server', () async {
    final alice = await user('alice');
    final bob = await user('bob');

    final id = await alice.startDirect('bob');
    expect(id, 'd_alice_bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false, reason: 'bob joins');

    await alice.send(id, 'oi bob, segredo 1234');
    await eventually(() => texts(bob, id).contains('oi bob, segredo 1234'));
    await bob.send(id, 'oi alice');
    await eventually(() => texts(alice, id).contains('oi alice'));

    expect(texts(alice, id), ['oi bob, segredo 1234', 'oi alice']);
    expect(alice.messages(id).first.outgoing, isTrue);
    expect(bob.messages(id).first.outgoing, isFalse);
    for (final e in server.publishLog.where((e) => e.conversationId == id)) {
      expect(utf8.decode(e.payload, allowMalformed: true), isNot(contains('segredo')));
    }
    // Starting again returns the same conversation.
    expect(await bob.startDirect('alice'), id);
  });

  test('cannot start a conversation with someone who never opened the app', () async {
    final alice = await user('alice');
    await expectLater(alice.startDirect('ghost'), throwsA(isA<NoKeyPackagesException>()));
  });

  test('groups: encrypted title, late joiner, removal', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final carol = await user('carol');

    final id = await alice.createGroup('Família', ['bob', 'carol']);
    await eventually(() => bob.conversation(id)?.title == 'Família' && carol.conversation(id)?.title == 'Família');
    expect(alice.conversation(id)!.memberUids..sort(), ['alice', 'bob', 'carol']);

    await bob.send(id, 'antes da dave');
    await eventually(() => texts(carol, id).contains('antes da dave'));

    final dave = await user('dave');
    await alice.addMember(id, 'dave');
    await eventually(() => dave.conversation(id)?.title == 'Família', reason: 'dave learns the title');
    expect(texts(dave, id), isEmpty, reason: 'no history for late joiners');

    await alice.removeMember(id, 'carol');
    await eventually(() => carol.conversation(id)?.ended ?? false, reason: 'carol removed');

    await bob.send(id, 'carol não lê');
    await eventually(() => texts(dave, id).contains('carol não lê'));
    expect(texts(carol, id), isNot(contains('carol não lê')));
    expect(alice.conversation(id)!.memberUids..sort(), ['alice', 'bob', 'dave']);
    expect(server.conversations[id]!.members.keys.toSet(), {'alice', 'bob', 'dave'});
  });

  test('only admins manage members and rename', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    await user('carol');
    final id = await alice.createGroup('G', ['bob']);
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);
    await expectLater(bob.addMember(id, 'carol'), throwsA(isA<NotAllowedException>()));
    await expectLater(bob.rename(id, 'Hack'), throwsA(isA<NotAllowedException>()));
  });

  test('concurrent key rotations converge', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final id = await alice.startDirect('bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);

    await Future.wait([alice.rotateKeys(id), bob.rotateKeys(id)]);
    await eventually(
      () => alice.engine.epoch(groupId: utf8.encode(id)) == bob.engine.epoch(groupId: utf8.encode(id)),
      reason: 'same epoch',
    );
    expect(server.conversations[id]!.epoch, 3);

    await bob.send(id, 'depois da rotação');
    await eventually(() => texts(alice, id).contains('depois da rotação'));
  });

  test('state and history survive a restart', () async {
    final alice = await user('alice');
    final bobStore = MemorySecureStore();
    var bob = await user('bob', store: bobStore);
    final id = await alice.startDirect('bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);
    await alice.send(id, 'primeira');
    await eventually(() => texts(bob, id).contains('primeira'));

    await bob.dispose();
    services.remove(bob);
    await alice.send(id, 'enquanto bob estava fora');

    bob = await user('bob', store: bobStore);
    await eventually(() => texts(bob, id).contains('enquanto bob estava fora'));
    expect(texts(bob, id), ['primeira', 'enquanto bob estava fora'], reason: 'no duplicates after restart');
    expect(utf8.decode(bobStore.data['mls_state']!, allowMalformed: true), isNot(contains('bob')));
  });

  test('a member who leaves is removed from the MLS group by an admin', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final carol = await user('carol');
    final id = await alice.createGroup('G', ['bob', 'carol']);
    await eventually(() => carol.conversation(id)?.pendingWelcome == false);

    await carol.leave(id);
    await eventually(() => !alice.conversation(id)!.memberUids.contains('carol'), reason: 'admin reconciled');
    await eventually(() => !bob.conversation(id)!.memberUids.contains('carol'));
    expect(carol.conversation(id)!.ended, isTrue, reason: 'the history stays, marked as ended');
  });

  group('visibility window', () {
    Future<(MessagingService, MessagingService, String)> pair() async {
      final alice = await user('alice');
      final bob = await user('bob');
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      return (alice, bob, id);
    }

    test('nothing is ever deleted by time: only hidden, and only for the receiver', () async {
      final (alice, bob, id) = await pair();
      await alice.setVisibilityWindow(id, const Duration(minutes: 1));
      await eventually(
        () => bob.conversation(id)?.visibilityWindow == const Duration(minutes: 1),
        reason: 'bob learns the window',
      );

      await alice.send(id, 'segredo');
      await eventually(() => texts(bob, id).contains('segredo'));
      await bob.markViewed(id); // bob opens the conversation: the window starts

      expect(texts(bob, id), contains('segredo'));
      now = now.add(const Duration(seconds: 59));
      expect(texts(bob, id), contains('segredo'), reason: 'still inside the window');

      now = now.add(const Duration(seconds: 2));
      final hidden = bob.messages(id).singleWhere((m) => !m.outgoing && m.senderUid == 'alice');
      expect(hidden.hidden, isTrue);
      expect(hidden.text, isEmpty, reason: 'a hidden message exposes no text');
      expect(bob.conversation(id)!.lastMessage!.text, isEmpty, reason: 'the list preview must not leak it either');

      expect(texts(alice, id), ['segredo'], reason: 'own messages never hide');
    });

    test('the window starts when the message is first shown, not when it arrives', () async {
      final (alice, bob, id) = await pair();
      await alice.setVisibilityWindow(id, const Duration(minutes: 1));
      await eventually(() => bob.conversation(id)?.visibilityWindow != null);
      await alice.send(id, 'chegou offline');
      await eventually(() => texts(bob, id).contains('chegou offline'));

      now = now.add(const Duration(hours: 5)); // bob did not look at it for hours
      expect(texts(bob, id), contains('chegou offline'));
      await bob.markViewed(id);
      expect(texts(bob, id), contains('chegou offline'));
      now = now.add(const Duration(minutes: 2));
      expect(bob.messages(id).last.hidden, isTrue);
    });

    test('the receiver can ask to see it again, for the same window, and it stays stored', () async {
      final (alice, bob, id) = await pair();
      await alice.setVisibilityWindow(id, const Duration(minutes: 1));
      await eventually(() => bob.conversation(id)?.visibilityWindow != null);
      await alice.send(id, 'de novo');
      await eventually(() => texts(bob, id).contains('de novo'));
      await bob.markViewed(id);
      now = now.add(const Duration(minutes: 2));
      final msg = bob.messages(id).last;
      expect(msg.hidden, isTrue);

      await bob.requestReveal(id, msg.id);
      expect(texts(bob, id), contains('de novo'));
      now = now.add(const Duration(seconds: 61));
      expect(bob.messages(id).last.hidden, isTrue, reason: 'hidden again after the same window');
      await bob.requestReveal(id, msg.id);
      expect(texts(bob, id), contains('de novo'), reason: 'can be asked again');
    });

    test('the hidden state survives a restart, and the text is still on the device', () async {
      final store = MemorySecureStore();
      final alice = await user('alice');
      var bob = await user('bob', store: store);
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      await alice.setVisibilityWindow(id, const Duration(minutes: 1));
      await eventually(() => bob.conversation(id)?.visibilityWindow != null);
      await alice.send(id, 'persiste');
      await eventually(() => texts(bob, id).contains('persiste'));
      await bob.markViewed(id);
      await bob.dispose();
      services.remove(bob);

      now = now.add(const Duration(minutes: 5));
      bob = await user('bob', store: store);
      expect(bob.messages(id).last.hidden, isTrue);
      await bob.requestReveal(id, bob.messages(id).last.id);
      expect(texts(bob, id), contains('persiste'), reason: 'never deleted, only hidden');
    });

    test('turning it off shows everything again; turning it on covers what is already stored', () async {
      final (alice, bob, id) = await pair();
      await alice.send(id, 'antiga');
      await eventually(() => texts(bob, id).contains('antiga'));
      await bob.markViewed(id); // no window: nothing happens
      expect(bob.messages(id).last.hidden, isFalse);

      await alice.setVisibilityWindow(id, const Duration(minutes: 1));
      await eventually(() => bob.conversation(id)?.visibilityWindow != null);
      now = now.add(const Duration(minutes: 2));
      expect(bob.messages(id).last.hidden, isTrue, reason: 'existing messages get the window too');

      await alice.setVisibilityWindow(id, null);
      await eventually(() => bob.conversation(id)?.visibilityWindow == null);
      expect(texts(bob, id), contains('antiga'));
    });

    test('in a 1:1 either person sets it; in a group only admins, and members learn it', () async {
      final (alice, bob, id) = await pair();
      await bob.setVisibilityWindow(id, const Duration(hours: 1));
      await eventually(() => alice.conversation(id)?.visibilityWindow == const Duration(hours: 1));

      final carol = await user('carol');
      final gid = await alice.createGroup('Time', ['bob', 'carol']);
      await eventually(() => bob.conversation(gid)?.pendingWelcome == false);
      await eventually(() => carol.conversation(gid)?.pendingWelcome == false);
      await expectLater(bob.setVisibilityWindow(gid, const Duration(minutes: 1)), throwsA(isA<NotAllowedException>()));

      await alice.setVisibilityWindow(gid, const Duration(minutes: 10));
      await eventually(() => carol.conversation(gid)?.visibilityWindow == const Duration(minutes: 10));

      final dave = await user('dave');
      await alice.addMember(gid, 'dave');
      await eventually(
        () => dave.conversation(gid)?.visibilityWindow == const Duration(minutes: 10),
        reason: 'newcomer learns the window',
      );
    });

    test('a member who is not admin can not impose a window by forging the payload', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final carol = await user('carol');
      final gid = await alice.createGroup('Time', ['bob', 'carol']);
      await eventually(() => bob.conversation(gid)?.pendingWelcome == false);
      await eventually(() => carol.conversation(gid)?.pendingWelcome == false);
      // Bob bypasses the API check and sends the meta payload himself.
      await bob.sendPayloadForTest(gid, {'t': 'meta', 'vis': 5});
      await bob.send(gid, 'oi');
      await eventually(() => texts(carol, gid).contains('oi'));
      expect(carol.conversation(gid)!.visibilityWindow, isNull);
    });
  });

  test('an ended conversation keeps its history until the person deletes it', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final carol = await user('carol');
    final id = await alice.createGroup('Time', ['bob', 'carol']);
    await eventually(() => carol.conversation(id)?.pendingWelcome == false);
    await alice.send(id, 'antes de sair');
    await eventually(() => texts(carol, id).contains('antes de sair'));

    await expectLater(carol.deleteConversation(id), throwsA(isA<NotAllowedException>()), reason: 'still active');
    await carol.leave(id);
    await eventually(() => carol.conversation(id)?.ended ?? false);
    expect(texts(carol, id), contains('antes de sair'), reason: 'leaving does not delete history');

    await carol.deleteConversation(id);
    expect(carol.conversation(id), isNull);
    expect(bob.conversation(id), isNotNull);
  });

  test('sending retries after a transient failure', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final id = await alice.startDirect('bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);
    server.failNextWrite = true;
    await alice.send(id, 'chegou mesmo assim');
    await eventually(() => texts(bob, id).contains('chegou mesmo assim'));
  });

  group('identity verification (stage 7)', () {
    test('keys are pinned on first sight and safety numbers match', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);

      expect(alice.keyStatus('bob'), KeyStatus.pinned);
      await eventually(() => bob.keyStatus('alice') == KeyStatus.pinned);
      expect(alice.keyStatus('stranger'), KeyStatus.unknown);
      final a = await alice.safetyNumberWith('bob');
      final b = await bob.safetyNumberWith('alice');
      expect(a, hasLength(60));
      expect(a, b);

      await alice.markVerified('bob');
      expect(alice.keyStatus('bob'), KeyStatus.verified);
    });

    test('a changed key is flagged everywhere until verified again', () async {
      final alice = await user('alice');
      var bob = await user('bob');
      final carol = await user('carol');
      final id = await alice.createGroup('G', ['bob', 'carol']);
      await eventually(
        () => carol.keyStatus('bob') == KeyStatus.pinned && bob.conversation(id)?.pendingWelcome == false,
      );
      await carol.markVerified('bob');
      final before = await carol.safetyNumberWith('bob');

      // Bob reinstalls the app: new identity key on a fresh device.
      await bob.dispose();
      services.remove(bob);
      server.keyPackages.remove('bob');
      bob = await user('bob');
      await alice.removeMember(id, 'bob');
      await alice.addMember(id, 'bob');
      await eventually(() => carol.keyStatus('bob') == KeyStatus.changed, reason: 'carol notices');
      await eventually(() => alice.keyStatus('bob') == KeyStatus.changed, reason: 'alice notices');

      expect(carol.conversation(id)!.keyChanged, isTrue);
      expect(texts(carol, id).any((t) => t.contains('chave de segurança')), isTrue);
      final after = await carol.safetyNumberWith('bob');
      expect(after, isNot(before));
      expect(
        after,
        await bob.safetyNumberWith('carol') ?? after,
        reason: 'new number matches the new device once bob sees carol',
      );

      await carol.markVerified('bob');
      expect(carol.keyStatus('bob'), KeyStatus.verified);
      expect(carol.conversation(id)!.keyChanged, isFalse);
      expect(await carol.safetyNumberWith('bob'), after);
    });
  });

  group('new device or reinstall (rejoin, no history)', () {
    test('direct chat is repaired and keeps working', () async {
      final alice = await user('alice');
      var bob = await user('bob');
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      await alice.send(id, 'antes');
      await eventually(() => texts(bob, id).contains('antes'));

      await bob.dispose();
      services.remove(bob);
      server.keyPackages.remove('bob');
      bob = await user('bob'); // fresh device: nothing carried over
      expect(await bob.startDirect('alice'), id);
      await eventually(() => bob.conversation(id)?.pendingWelcome == false, reason: 'alice re-invites bob');
      await eventually(() => alice.keyStatus('bob') == KeyStatus.changed, reason: 'new device = new key');
      expect(server.rejoin[id] ?? <String>{}, isEmpty);

      await bob.send(id, 'voltei num aparelho novo');
      await eventually(() => texts(alice, id).contains('voltei num aparelho novo'));
      await alice.send(id, 'bem-vindo de volta');
      await eventually(() => texts(bob, id).contains('bem-vindo de volta'));
      expect(texts(bob, id), isNot(contains('antes')), reason: 'old history stays only on the old device');
    });

    test('in groups only admins repair; title is re-sent', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      var carol = await user('carol');
      final id = await alice.createGroup('Turma', ['bob', 'carol']);
      await eventually(() => carol.conversation(id)?.title == 'Turma' && bob.conversation(id)?.pendingWelcome == false);

      await carol.dispose();
      services.remove(carol);
      server.keyPackages.remove('carol');
      carol = await user('carol');
      await eventually(
        () => carol.conversation(id)?.title == 'Turma',
        reason: 'admin re-invited and re-sent the title',
      );
      await bob.send(id, 'oi carol');
      await eventually(() => texts(carol, id).contains('oi carol'));
      expect(alice.conversation(id)!.memberUids.where((m) => m == 'carol'), hasLength(1));
    });
  });

  group('lost commits after a long absence (R7)', () {
    test('a member who missed pruned commits is reconnected automatically', () async {
      final alice = await user('alice');
      final bobStore = MemorySecureStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.createGroup('Turma', ['bob']);
      await eventually(() => bob.conversation(id)?.pendingWelcome == false && bob.conversation(id)?.title == 'Turma');
      await alice.send(id, 'antes de sair');
      await eventually(() => texts(bob, id).contains('antes de sair'));
      final before = texts(bob, id).length;

      // Bob goes offline; the group moves on by two epochs.
      await bob.dispose();
      services.remove(bob);
      await alice.rotateKeys(id);
      await alice.rotateKeys(id);
      await alice.send(id, 'enquanto bob estava fora');
      final serverEpoch = server.conversations[id]!.epoch;
      expect(serverEpoch, greaterThan(2));

      // Retention deletes the intermediate commits (epochs 2..n).
      server.pruneEnvelopes(id, (e) => e.kind == EnvelopeKind.commit && e.epoch > 1);

      bob = await user('bob', store: bobStore);
      await eventually(() => texts(bob, id).any((t) => t.contains('muito tempo offline')), reason: 'gap detected');
      await eventually(
        () =>
            bob.conversation(id)?.pendingWelcome == false &&
            bob.engine.epoch(groupId: utf8.encode(id)).toInt() >= serverEpoch,
        reason: 'alice re-invites bob',
      );
      await eventually(() => (server.rejoin[id] ?? <String>{}).isEmpty, reason: 'request cleared after rejoin');
      expect(texts(bob, id).length, greaterThan(before), reason: 'history kept, plus the system notice');
      expect(texts(bob, id), contains('antes de sair'));

      await bob.send(id, 'voltei');
      await eventually(() => texts(alice, id).contains('voltei'));
      await alice.send(id, 'bem-vindo de volta');
      await eventually(() => texts(bob, id).contains('bem-vindo de volta'));
      expect(alice.conversation(id)!.memberUids.where((m) => m == 'bob'), hasLength(1), reason: 'no duplicate leaf');
    });

    test('a member that is only slightly behind is NOT reset', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final id = await alice.createGroup('G', ['bob']);
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      await alice.rotateKeys(id);
      await alice.send(id, 'normal');
      await eventually(() => texts(bob, id).contains('normal'));
      await Future<void>.delayed(const Duration(milliseconds: 900)); // longer than gapDelay
      expect(texts(bob, id).any((t) => t.contains('muito tempo offline')), isFalse);
      expect(bob.conversation(id)!.pendingWelcome, isFalse);
    });

    test('with several admins only the elected one repairs', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final carol = await user('carol');
      final id = await alice.createGroup('G', ['bob', 'carol']);
      await eventually(
        () => bob.conversation(id)?.pendingWelcome == false && carol.conversation(id)?.pendingWelcome == false,
      );
      // Promote bob to admin on the server record (as the group's admins would).
      final r = server.conversations[id]!;
      server.conversations[id] = ConversationRecord(
        id: r.id,
        type: r.type,
        createdBy: r.createdBy,
        epoch: r.epoch,
        members: {...r.members, 'bob': MemberRole.admin},
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      var carolReset = carol;
      await carol.dispose();
      services.remove(carol);
      server.keyPackages.remove('carol');
      carolReset = await user('carol');
      await eventually(() => carolReset.conversation(id)?.pendingWelcome == false, reason: 'repaired');
      final epochs = server.publishLog
          .where((e) => e.conversationId == id && e.kind == EnvelopeKind.commit)
          .map((e) => e.epoch)
          .toList();
      expect(epochs.toSet().length, epochs.length, reason: 'each epoch committed exactly once');
      expect(alice.conversation(id)!.memberUids.where((m) => m == 'carol'), hasLength(1));
    });
  });

  group('draining key packages (R4)', () {
    test('invites still work after the whole pool is consumed (last resort)', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      server.keyPackages['bob']!.clear(); // a griefer drained bob's pool
      expect(server.lastResort['bob'], isNotNull);

      final id = await alice.startDirect('bob');
      await eventually(
        () => bob.conversation(id)?.pendingWelcome == false,
        reason: 'bob joins via the last resort package',
      );
      await alice.send(id, 'ainda consigo falar com bob');
      await eventually(() => texts(bob, id).contains('ainda consigo falar com bob'));

      // The same reusable package serves a second conversation.
      final carol = await user('carol');
      final g = await carol.createGroup('G', ['bob']);
      await eventually(() => bob.conversation(g)?.pendingWelcome == false);
      expect(server.lastResort['bob'], isNotNull, reason: 'never consumed');
    });

    test('claims are rate limited per person, with a friendly message in the UI layer', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      server.currentCaller = 'alice';
      for (var i = 0; i < MemoryConversationBackend.claimsPerHour; i++) {
        await server.claimKeyPackage('bob');
      }
      await expectLater(alice.startDirect('bob'), throwsA(isA<RateLimitedException>()));
      expect(bob.conversations(), isEmpty);
    });

    test('old pool and last resort are replaced before they expire', () async {
      final store = MemorySecureStore();
      final alice = await user('alice', store: store);
      final firstPool = server.keyPackages['alice']!.map(base64Encode).toSet();
      final firstLast = base64Encode(server.lastResort['alice']!);
      await alice.dispose();
      services.remove(alice);

      now = now.add(const Duration(days: 20));
      await user('alice', store: store);
      expect(base64Encode(server.lastResort['alice']!), firstLast, reason: 'still fresh');

      now = now.add(const Duration(days: 15)); // 35 days: last resort renewed, pool kept
      await (await user('alice', store: store)).dispose();
      expect(base64Encode(server.lastResort['alice']!), isNot(firstLast));
      expect(server.keyPackages['alice']!.map(base64Encode).toSet(), firstPool);

      now = now.add(const Duration(days: 20)); // 55 days: pool replaced entirely
      await user('alice', store: store);
      expect(server.keyPackages['alice']!.map(base64Encode).toSet().intersection(firstPool), isEmpty);
      expect(server.keyPackages['alice'], hasLength(20));
    });
  });

  group('malicious ordinary member (R3)', () {
    Future<(MessagingService, MessagingService, MessagingService, String)> team() async {
      final alice = await user('alice');
      final bob = await user('bob');
      final mallory = await user('mallory');
      final id = await alice.createGroup('Equipe', ['bob', 'mallory']);
      await eventually(
        () => bob.conversation(id)?.pendingWelcome == false && mallory.conversation(id)?.pendingWelcome == false,
        reason: 'everyone joined',
      );
      await eventually(() => bob.conversation(id)?.title == 'Equipe');
      return (alice, bob, mallory, id);
    }

    List<String> membersOf(MessagingService s, String id) => s.conversation(id)!.memberUids.toList()..sort();

    test('the server refuses a commit from an ordinary member', () async {
      final (alice, bob, mallory, id) = await team();
      final out = await mallory.engine.removeMembers(groupId: utf8.encode(id), identities: [utf8.encode('bob')]);
      final evil = Envelope(
        id: server.newEnvelopeId(id),
        conversationId: id,
        sender: 'mallory',
        epoch: out.newEpoch.toInt(),
        kind: EnvelopeKind.commit,
        payload: out.commit,
      );
      await expectLater(server.publishCommit(commit: evil), throwsA(isA<StateError>()));
      expect(server.conversations[id]!.epoch, 1, reason: 'epoch untouched');
      expect(server.conversations[id]!.members.keys.toSet(), {'alice', 'bob', 'mallory'});
      expect(membersOf(alice, id), ['alice', 'bob', 'mallory']);
      expect(membersOf(bob, id), ['alice', 'bob', 'mallory']);
    });

    test('a commit hidden in a message or proposal envelope is refused by every honest client', () async {
      final (alice, bob, mallory, id) = await team();
      final out = await mallory.engine.removeMembers(groupId: utf8.encode(id), identities: [utf8.encode('bob')]);
      final epoch = server.conversations[id]!.epoch;
      for (final kind in [EnvelopeKind.application, EnvelopeKind.proposal]) {
        final disguised = Envelope(
          id: server.newEnvelopeId(id),
          conversationId: id,
          sender: 'mallory',
          epoch: epoch,
          kind: kind,
          payload: out.commit,
        );
        // The server only sees the label, so it accepts these...
        kind == EnvelopeKind.application
            ? await server.publishApplication(disguised)
            : await server.publishProposal(disguised);
      }
      // ...but the receivers check the content and apply nothing.
      await eventually(
        () => texts(alice, id).where((t) => t.contains('não pôde ser decifrada') || t.contains('inválida')).length >= 2,
        reason: 'alice noticed both attempts',
      );
      expect(alice.engine.epoch(groupId: utf8.encode(id)).toInt(), epoch);
      expect(membersOf(alice, id), ['alice', 'bob', 'mallory']);
      expect(membersOf(bob, id), ['alice', 'bob', 'mallory']);

      // The group still works for everybody.
      await alice.send(id, 'seguimos juntos');
      await eventually(() => texts(bob, id).contains('seguimos juntos'));
      await bob.send(id, 'ok');
      await eventually(() => texts(alice, id).contains('ok'));
    });

    test('an ordinary member rotates keys through a proposal that an admin commits', () async {
      final (alice, bob, _, id) = await team();
      final before = alice.engine.epoch(groupId: utf8.encode(id)).toInt();
      await bob.rotateKeys(id); // bob cannot commit: he sends a proposal
      expect(server.publishLog.any((e) => e.kind == EnvelopeKind.proposal && e.sender == 'bob'), isTrue);
      await eventually(
        () => alice.engine.epoch(groupId: utf8.encode(id)).toInt() > before,
        reason: 'the admin committed bob\'s proposal',
      );
      await eventually(
        () => bob.engine.epoch(groupId: utf8.encode(id)) == alice.engine.epoch(groupId: utf8.encode(id)),
        reason: 'bob followed',
      );
      expect(server.publishLog.where((e) => e.kind == EnvelopeKind.commit && e.sender == 'bob'), isEmpty);
      expect(alice.engine.hasPendingProposals(groupId: utf8.encode(id)), isFalse, reason: 'consumed');

      await bob.send(id, 'chaves novas');
      await eventually(() => texts(alice, id).contains('chaves novas'));
    });
  });

  group('carrier: the server forgets what it delivered', () {
    /// What the server still holds of a conversation's traffic.
    int held(String id) => server.envelopes[id]?.length ?? 0;

    /// The Welcome is deleted only at the very end of joining, after the new state is saved.
    Future<void> joined(String uid, MessagingService s, String id) => eventually(
      () => (server.welcomes[uid] ?? []).isEmpty && s.conversation(id)?.pendingWelcome == false,
      reason: '$uid finished joining',
    );

    test('after delivery nothing is left on the server: no message, no ciphertext, no history', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);

      await alice.send(id, 'primeira');
      await eventually(() => texts(bob, id).contains('primeira'));
      await bob.send(id, 'segunda');
      await eventually(() => texts(alice, id).contains('segunda'));

      await eventually(() => held(id) == 0, reason: 'the carrier forgot both envelopes');
      // The messages exist, but only on the devices.
      expect(texts(alice, id), ['primeira', 'segunda']);
      expect(texts(bob, id), ['primeira', 'segunda']);
      expect(
        server.publishLog.where((e) => e.conversationId == id && e.kind == EnvelopeKind.application),
        hasLength(2),
      );
    });

    test('an offline recipient keeps the message waiting, and it is forgotten once they have it', () async {
      final alice = await user('alice');
      final bobStore = MemorySecureStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);

      await bob.dispose();
      services.remove(bob);
      await alice.send(id, 'enquanto você estava fora');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(held(id), 1, reason: 'waiting for bob');

      bob = await user('bob', store: bobStore);
      await eventually(() => texts(bob, id).contains('enquanto você estava fora'));
      await eventually(() => held(id) == 0, reason: 'delivered, so forgotten');
    });

    test('in a group the message waits for EVERY member and is forgotten only after the last one', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final carolStore = MemorySecureStore();
      var carol = await user('carol', store: carolStore);
      final id = await alice.createGroup('Turma', ['bob', 'carol']);
      await eventually(() => bob.conversation(id)?.pendingWelcome == false && carol.conversation(id)?.title == 'Turma');
      await eventually(() => held(id) == 0, reason: 'the title message was delivered to everybody');

      await carol.dispose();
      services.remove(carol);
      await alice.send(id, 'para todos');
      await eventually(() => texts(bob, id).contains('para todos'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(held(id), 1, reason: 'bob has it, carol does not: still waiting');

      carol = await user('carol', store: carolStore);
      await eventually(() => texts(carol, id).contains('para todos'));
      await eventually(() => held(id) == 0, reason: 'everybody has it now');
    });

    test('someone who leaves no longer holds a message back', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final carolStore = MemorySecureStore();
      var carol = await user('carol', store: carolStore);
      final id = await alice.createGroup('Turma', ['bob', 'carol']);
      await eventually(() => carol.conversation(id)?.title == 'Turma' && bob.conversation(id)?.pendingWelcome == false);
      await eventually(() => held(id) == 0);

      await carol.dispose();
      services.remove(carol);
      await alice.send(id, 'carol nunca vai receber');
      await eventually(() => texts(bob, id).contains('carol nunca vai receber'));
      await eventually(
        () => server.waitingFor(id).length == 1 && server.waitingFor(id).contains('carol'),
        reason: 'only carol is missing',
      );
      expect(held(id), 1);

      await server.leaveConversation(uid: 'carol', conversationId: id);
      expect(held(id), 0, reason: 'only carol was missing, and she is gone');
    });

    test('safety net: an envelope nobody picked up expires, and a late member rejoins without it', () async {
      final alice = await user('alice');
      final bobStore = MemorySecureStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);

      await bob.dispose();
      services.remove(bob);
      await alice.send(id, 'ninguém buscou');
      expect(held(id), 1);
      server.pruneEnvelopes(id, (_) => true); // 7 days passed

      expect(held(id), 0);
      bob = await user('bob', store: bobStore);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(texts(bob, id), isNot(contains('ninguém buscou')), reason: 'lost for good: no copy anywhere else');
      await alice.send(id, 'depois');
      await eventually(() => texts(bob, id).contains('depois'));
    });

    test('a message is NEVER confirmed before it is safely stored on the device', () async {
      final alice = await user('alice');
      final bobStore = FlakyStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.startDirect('bob');
      await joined('bob', bob, id); // the join itself must be fully saved before the disk "fills up"

      bobStore.failWrites = true; // the disk is full
      await alice.send(id, 'não pode se perder');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(held(id), 1, reason: 'bob could not store it, so the carrier must keep it');

      await bob.dispose();
      services.remove(bob);
      bobStore.failWrites = false;
      bob = await user('bob', store: bobStore);
      await eventually(() => texts(bob, id).contains('não pode se perder'), reason: 'delivered after the restart');
      await eventually(() => held(id) == 0, reason: 'and only now forgotten');
    });

    test('an app that crashed after storing but before confirming confirms again, without duplicates', () async {
      final alice = await user('alice');
      final bobStore = MemorySecureStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);

      server.dropAcks = true; // the confirmations never reach the server
      await alice.send(id, 'uma vez só');
      await eventually(() => texts(bob, id).contains('uma vez só'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(held(id), 1, reason: 'stored by bob, but the server was not told');

      await bob.dispose();
      services.remove(bob);
      server.dropAcks = false;
      bob = await user('bob', store: bobStore);
      await eventually(() => held(id) == 0, reason: 'the replay is confirmed again');
      expect(texts(bob, id).where((t) => t == 'uma vez só'), hasLength(1), reason: 'no duplicate');
    });
  });

  group('each person owns their history', () {
    test('deleting a message removes it from this device only, and stays deleted after a restart', () async {
      final alice = await user('alice');
      final bobStore = MemorySecureStore();
      var bob = await user('bob', store: bobStore);
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      await alice.send(id, 'fica com a alice');
      await alice.send(id, 'o bob apaga');
      await eventually(() => texts(bob, id).contains('o bob apaga'));

      final doomed = bob.messages(id).firstWhere((m) => m.text == 'o bob apaga');
      await bob.deleteMessage(id, doomed.id);
      expect(texts(bob, id), ['fica com a alice']);
      expect(texts(alice, id), ['fica com a alice', 'o bob apaga'], reason: 'the other person keeps their own copy');

      await bob.dispose();
      services.remove(bob);
      bob = await user('bob', store: bobStore);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(texts(bob, id), ['fica com a alice'], reason: 'the server holds nothing to bring it back');
    });

    test('clearing the history empties this device but the conversation keeps working', () async {
      final alice = await user('alice');
      final bob = await user('bob');
      final id = await alice.startDirect('bob');
      await eventually(() => bob.conversation(id)?.pendingWelcome == false);
      await alice.send(id, 'um');
      await bob.send(id, 'dois');
      await eventually(() => texts(alice, id).contains('dois') && texts(bob, id).contains('um'));

      await bob.clearHistory(id);
      expect(texts(bob, id), isEmpty);
      expect(texts(alice, id), ['um', 'dois']);

      await alice.send(id, 'três');
      await eventually(() => texts(bob, id).contains('três'));
      expect(texts(bob, id), ['três'], reason: 'only what arrives after the clean-up');
    });

    test('deleting something that does not exist is harmless', () async {
      final alice = await user('alice');
      await alice.deleteMessage('nao-existe', 'x');
      await alice.clearHistory('nao-existe');
    });
  });
}

/// A store whose writes can be made to fail (a full disk).
class FlakyStore extends MemorySecureStore {
  bool failWrites = false;

  @override
  Future<void> write(String name, Uint8List value) {
    if (failWrites) throw const FileSystemException('no space left on device');
    return super.write(name, value);
  }
}
