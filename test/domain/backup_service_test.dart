import 'dart:convert';
import 'dart:io';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/domain/services/backup_service.dart';
import 'package:myapp/domain/services/messaging_service.dart';

import '../fakes/memory_backup_backend.dart';
import '../fakes/memory_conversation_backend.dart';
import '../fakes/memory_secure_store.dart';

Future<void> eventually(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 300; i++) {
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
  late MemoryBackupBackend backups;
  late DateTime now;
  final running = <MessagingService>[];

  Future<MessagingService> start(String uid, MemorySecureStore store) async {
    final s = MessagingService(backend: server, store: store, uid: uid, clock: () => now);
    await s.start();
    running.add(s);
    return s;
  }

  setUp(() {
    server = MemoryConversationBackend();
    backups = MemoryBackupBackend();
    now = DateTime(2026, 11, 19, 12);
  });

  tearDown(() async {
    for (final s in running) {
      await s.dispose();
    }
    running.clear();
  });

  test('restore on a new phone keeps history, identity and keeps talking', () async {
    final alice = await start('alice', MemorySecureStore());
    final oldStore = MemorySecureStore();
    final bob = await start('bob', oldStore);
    final id = await alice.startDirect('bob');
    await eventually(() => bob.conversation(id)?.pendingWelcome == false);
    await alice.send(id, 'antes do backup');
    await eventually(() => texts(bob, id).contains('antes do backup'));

    final bobBackup = BackupService(backend: backups, store: oldStore, uid: 'bob', clock: () => now);
    final code = await bobBackup.enable(bob);
    expect(isValidRecoveryCode(code: code), isTrue);
    expect(utf8.decode(backups.blobs['bob']!, allowMalformed: true), isNot(contains('antes do backup')));
    final oldKps = server.keyPackages['bob']!.map(base64Encode).toSet();

    // Phone lost.
    await bob.dispose();
    running.remove(bob);
    await alice.send(id, 'enquanto bob trocava de celular');

    final newStore = MemorySecureStore();
    final restorer = BackupService(backend: backups, store: newStore, uid: 'bob', clock: () => now);
    await expectLater(
      restorer.restore(generateRecoveryCode()),
      throwsA(isA<BackupException>().having((e) => e.error, 'error', BackupError.wrongCode)),
    );
    await expectLater(
      restorer.restore('codigo invalido'),
      throwsA(isA<BackupException>().having((e) => e.error, 'error', BackupError.invalidCode)),
    );
    await restorer.restore(code.toLowerCase().replaceAll('-', ' '));

    final bob2 = await start('bob', newStore);
    expect(
      bob2.signaturePublicKey,
      alice.engine
          .memberKeys(groupId: utf8.encode(id))
          .firstWhere((m) => utf8.decode(m.identity) == 'bob')
          .signatureKey,
    );
    await eventually(() => texts(bob2, id).contains('enquanto bob trocava de celular'), reason: 'catches up');
    expect(texts(bob2, id).first, 'antes do backup', reason: 'history restored');

    // Old KeyPackages were replaced: their private parts may be stale.
    final newKps = server.keyPackages['bob']!.map(base64Encode).toSet();
    expect(newKps.intersection(oldKps), isEmpty);

    await bob2.send(id, 'voltei');
    await eventually(() => texts(alice, id).contains('voltei'));
    expect(alice.keyStatus('bob'), KeyStatus.pinned, reason: 'same identity: no key-change warning');
  });

  test('a backup only opens for its own account and with the server share', () async {
    final store = MemorySecureStore();
    final alice = await start('alice', store);
    final code = await BackupService(backend: backups, store: store, uid: 'alice').enable(alice);

    // Someone else copying the blob into their account.
    backups.blobs['mallory'] = backups.blobs['alice']!;
    backups.shares['mallory'] = backups.shares['alice']!;
    await expectLater(
      BackupService(backend: backups, store: MemorySecureStore(), uid: 'mallory').restore(code),
      throwsA(isA<BackupException>().having((e) => e.error, 'error', BackupError.wrongAccount)),
    );

    // Without the server share the code alone is useless.
    backups.shares.remove('alice');
    await expectLater(
      BackupService(backend: backups, store: MemorySecureStore(), uid: 'alice').restore(code),
      throwsA(isA<BackupException>().having((e) => e.error, 'error', BackupError.noServerShare)),
    );
  });

  test('disable deletes the server copy; auto backup runs once a day', () async {
    final store = MemorySecureStore();
    final alice = await start('alice', store);
    final svc = BackupService(backend: backups, store: store, uid: 'alice', clock: () => now);
    await svc.enable(alice);
    final first = backups.blobs['alice'];

    now = now.add(const Duration(hours: 1));
    await svc.maybeAutoBackup(alice);
    expect(identical(backups.blobs['alice'], first), isTrue, reason: 'too soon');
    now = now.add(const Duration(hours: 24));
    await svc.maybeAutoBackup(alice);
    expect(identical(backups.blobs['alice'], first), isFalse);

    await svc.disable();
    expect(await svc.isEnabled(), isFalse);
    expect(backups.blobs['alice'], isNull);
    expect(backups.shares['alice'], isNull);
    await expectLater(
      BackupService(backend: backups, store: MemorySecureStore(), uid: 'alice').restore(generateRecoveryCode()),
      throwsA(isA<BackupException>().having((e) => e.error, 'error', BackupError.noBackup)),
    );
  });
}
