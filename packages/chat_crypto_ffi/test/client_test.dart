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

void main() {
  setUpAll(() async {
    final ext = Platform.isMacOS ? 'dylib' : 'so';
    final path = 'rust/target/debug/libchat_crypto_ffi.$ext';
    await RustLib.init(externalLibrary: ExternalLibrary.open(path));
  });

  final group = b('conversa-1');

  test('1:1 and group messages are encrypted and decrypted through the bridge', () async {
    final alice = ChatCryptoClient.create(identity: b('alice'));
    final bob = ChatCryptoClient.create(identity: b('bob'));
    final carol = ChatCryptoClient.create(identity: b('carol'));

    await alice.createGroup(groupId: group);
    final addBob = await alice.addMembers(groupId: group, keyPackages: [await bob.generateKeyPackage()]);
    expect(s(await bob.joinGroup(welcome: addBob.welcome)), 'conversa-1');

    final wire = await alice.encrypt(groupId: group, plaintext: b('olá bob'));
    expect(utf8.decode(wire, allowMalformed: true).contains('olá'), isFalse);
    final got = await bob.process(groupId: group, message: wire);
    expect(got.kind, IncomingKind.application);
    expect(s(got.sender), 'alice');
    expect(s(got.plaintext), 'olá bob');

    final addCarol = await alice.addMembers(groupId: group, keyPackages: [await carol.generateKeyPackage()]);
    final commit = await bob.process(groupId: group, message: addCarol.commit);
    expect(commit.kind, IncomingKind.commit);
    expect(commit.stillMember, isTrue);
    await carol.joinGroup(welcome: addCarol.welcome);

    expect(alice.members(groupId: group).map(s).toList(), ['alice', 'bob', 'carol']);
    expect(carol.epoch(groupId: group), BigInt.two);
    expect(carol.epochAuthenticator(groupId: group), alice.epochAuthenticator(groupId: group));

    final fromCarol = await carol.encrypt(groupId: group, plaintext: b('oi grupo'));
    expect(s((await alice.process(groupId: group, message: fromCarol)).plaintext), 'oi grupo');
    expect(s((await bob.process(groupId: group, message: fromCarol)).plaintext), 'oi grupo');
  });

  test('removed member is cut off and errors surface as Dart exceptions', () async {
    final alice = ChatCryptoClient.create(identity: b('alice'));
    final bob = ChatCryptoClient.create(identity: b('bob'));
    await alice.createGroup(groupId: group);
    await bob.joinGroup(
      welcome: (await alice.addMembers(groupId: group, keyPackages: [await bob.generateKeyPackage()])).welcome,
    );

    final removal = await alice.removeMembers(groupId: group, identities: [b('bob')]);
    final r = await bob.process(groupId: group, message: removal);
    expect(r.kind, IncomingKind.commit);
    expect(r.stillMember, isFalse);

    final secret = await alice.encrypt(groupId: group, plaintext: b('bob não lê'));
    await expectLater(bob.process(groupId: group, message: secret), throwsA(anything));
    expect(() => ChatCryptoClient.create(identity: []), throwsA(anything));
  });
}
