// End-to-end tests of MessagingService with the REAL Rust/MLS library (via
// FFI) and an in-memory server. Build the library first:
//   cargo build --manifest-path packages/chat_crypto_ffi/rust/Cargo.toml
import 'dart:convert';
import 'dart:io';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/domain/services/messaging_service.dart';

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
    final s = MessagingService(backend: server, store: store ?? MemorySecureStore(), uid: uid, clock: () => now);
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

  test('publishes identity and key packages on first start', () async {
    final alice = await user('alice');
    expect(server.identities['alice'], alice.signaturePublicKey);
    expect(server.keyPackages['alice'], hasLength(20));
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
    for (final e in server.envelopes[id]!) {
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
    await eventually(() => carol.conversations().every((c) => c.id != id), reason: 'carol removed');

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
    expect(carol.conversations(), isEmpty);
  });

  test('disappearing messages vanish on both sides', () async {
    final alice = await user('alice');
    final bob = await user('bob');
    final id = await alice.startDirect('bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);

    await alice.send(id, 'some em 1 minuto', disappearAfter: const Duration(minutes: 1));
    await alice.send(id, 'fica');
    await eventually(() => texts(bob, id).length == 2);

    now = now.add(const Duration(minutes: 2));
    await alice.purgeExpiredNow();
    await bob.purgeExpiredNow();
    expect(texts(alice, id), ['fica']);
    expect(texts(bob, id), ['fica']);
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
}
