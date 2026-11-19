// Runs ON a device/emulator: proves the Rust library is bundled and works there.
//   cd example && flutter test integration_test/simple_test.dart
import 'dart:convert';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  test('MLS round trip on device', () async {
    final group = utf8.encode('device-test');
    final alice = ChatCryptoClient.create(identity: utf8.encode('alice'));
    final bob = ChatCryptoClient.create(identity: utf8.encode('bob'));
    await alice.createGroup(groupId: group);
    final add = await alice.addMembers(groupId: group, keyPackages: [await bob.generateKeyPackage()]);
    await alice.mergePendingCommit(groupId: group);
    await bob.joinGroup(welcome: add.welcome!);
    final wire = await alice.encrypt(groupId: group, plaintext: utf8.encode('oi'));
    final msg = await bob.process(groupId: group, message: wire);
    expect(msg.kind, IncomingKind.application);
    expect(utf8.decode(msg.plaintext), 'oi');
  });
}
