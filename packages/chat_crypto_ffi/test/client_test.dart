// Host test of the Dart <-> Rust bridge (runs on the development machine,
// not on a device). Build the library first:
//   cargo build --manifest-path rust/Cargo.toml
import 'dart:convert';
import 'dart:io';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List b(String s) => utf8.encode(s);
String s(List<int> bytes) => utf8.decode(bytes);

Future<Uint8List> addAndMerge(
  ChatCryptoClient c,
  Uint8List group,
  List<Uint8List> kps, {
  List<ChatCryptoClient> others = const [],
}) async {
  final out = await c.addMembers(groupId: group, keyPackages: kps);
  await c.mergePendingCommit(groupId: group);
  for (final o in others) {
    await o.process(groupId: group, message: out.commit, expected: ExpectedContent.commit);
  }
  return out.welcome!;
}

void main() {
  setUpAll(() async {
    final ext = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/debug/libchat_crypto_ffi.$ext'));
  });

  final group = b('conversa-1');

  test('1:1 and group messages through the bridge', () async {
    final alice = ChatCryptoClient.create(identity: b('alice'));
    final bob = ChatCryptoClient.create(identity: b('bob'));
    final carol = ChatCryptoClient.create(identity: b('carol'));

    await alice.createGroup(groupId: group);
    expect(
      s(await bob.joinGroup(welcome: await addAndMerge(alice, group, [await bob.generateKeyPackage()]))),
      'conversa-1',
    );

    final wire = await alice.encrypt(groupId: group, plaintext: b('olá bob'));
    expect(utf8.decode(wire, allowMalformed: true).contains('olá'), isFalse);
    final got = await bob.process(groupId: group, message: wire, expected: ExpectedContent.application);
    expect(got.kind, IncomingKind.application);
    expect(s(got.sender), 'alice');
    expect(s(got.plaintext), 'olá bob');

    await carol.joinGroup(welcome: await addAndMerge(alice, group, [await carol.generateKeyPackage()], others: [bob]));
    expect(alice.members(groupId: group).map(s).toList(), ['alice', 'bob', 'carol']);
    expect(carol.epoch(groupId: group), BigInt.two);
    expect(carol.epochAuthenticator(groupId: group), alice.epochAuthenticator(groupId: group));
    expect(
      carol.memberKeys(groupId: group).firstWhere((m) => s(m.identity) == 'alice').signatureKey,
      alice.signaturePublicKey,
    );

    final fromCarol = await carol.encrypt(groupId: group, plaintext: b('oi grupo'));
    expect(
      s((await alice.process(groupId: group, message: fromCarol, expected: ExpectedContent.application)).plaintext),
      'oi grupo',
    );
    expect(
      s((await bob.process(groupId: group, message: fromCarol, expected: ExpectedContent.application)).plaintext),
      'oi grupo',
    );
  });

  test('removal, rejected commits and errors as exceptions', () async {
    final alice = ChatCryptoClient.create(identity: b('alice'));
    final bob = ChatCryptoClient.create(identity: b('bob'));
    await alice.createGroup(groupId: group);
    await bob.joinGroup(welcome: await addAndMerge(alice, group, [await bob.generateKeyPackage()]));

    final pending = await alice.selfUpdate(groupId: group);
    expect(pending.newEpoch, BigInt.two);
    await alice.clearPendingCommit(groupId: group);
    expect(alice.epoch(groupId: group), BigInt.one);

    final removal = await alice.removeMembers(groupId: group, identities: [b('bob')]);
    await alice.mergePendingCommit(groupId: group);
    final r = await bob.process(groupId: group, message: removal.commit, expected: ExpectedContent.commit);
    expect(r.kind, IncomingKind.commit);
    expect(r.stillMember, isFalse);

    final secret = await alice.encrypt(groupId: group, plaintext: b('bob não lê'));
    await expectLater(
      bob.process(groupId: group, message: secret, expected: ExpectedContent.application),
      throwsA(anything),
    );
    expect(() => ChatCryptoClient.create(identity: []), throwsA(anything));
  });

  test('state export/restore, vault and safety numbers', () async {
    final key = randomBytes(len: 32);
    final alice = ChatCryptoClient.create(identity: b('alice'));
    final bob = ChatCryptoClient.create(identity: b('bob'));
    await alice.createGroup(groupId: group);
    await bob.joinGroup(welcome: await addAndMerge(alice, group, [await bob.generateKeyPackage()]));

    final restored = await ChatCryptoClient.restore(
      state: await bob.exportState(key: key),
      key: key,
    );
    expect(restored.groupIds().map(s).toList(), ['conversa-1']);
    final wire = await alice.encrypt(groupId: group, plaintext: b('após restaurar'));
    expect(
      s((await restored.process(groupId: group, message: wire, expected: ExpectedContent.application)).plaintext),
      'após restaurar',
    );

    final sealed = await vaultSeal(key: key, context: b('f'), plaintext: b('histórico'));
    expect(s(await vaultOpen(key: key, context: b('f'), sealed: sealed)), 'histórico');
    await expectLater(vaultOpen(key: key, context: b('g'), sealed: sealed), throwsA(anything));

    final n1 = await safetyNumber(
      myIdentity: b('alice'),
      myKey: alice.signaturePublicKey,
      theirIdentity: b('bob'),
      theirKey: bob.signaturePublicKey,
    );
    final n2 = await safetyNumber(
      myIdentity: b('bob'),
      myKey: bob.signaturePublicKey,
      theirIdentity: b('alice'),
      theirKey: alice.signaturePublicKey,
    );
    expect(n1, hasLength(60));
    expect(n1, n2);
  });

  test('backup needs recovery code and server share', () async {
    final code = generateRecoveryCode();
    expect(isValidRecoveryCode(code: code), isTrue);
    expect(isValidRecoveryCode(code: 'abc'), isFalse);
    final share = randomBytes(len: 32);
    final blob = await backupSeal(recoveryCode: code, serverShare: share, plaintext: b('tudo'));
    expect(s(await backupOpen(recoveryCode: code.toLowerCase(), serverShare: share, blob: blob)), 'tudo');
    await expectLater(backupOpen(recoveryCode: code, serverShare: randomBytes(len: 32), blob: blob), throwsA(anything));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
