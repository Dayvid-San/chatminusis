import 'dart:convert';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter/material.dart';

/// Minimal on-device check: two in-memory clients exchange one encrypted message.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(MyApp(result: await _selfTest()));
}

Future<String> _selfTest() async {
  final group = utf8.encode('demo');
  final alice = ChatCryptoClient.create(identity: utf8.encode('alice'));
  final bob = ChatCryptoClient.create(identity: utf8.encode('bob'));
  await alice.createGroup(groupId: group);
  final add = await alice.addMembers(groupId: group, keyPackages: [await bob.generateKeyPackage()]);
  await alice.mergePendingCommit(groupId: group);
  await bob.joinGroup(welcome: add.welcome!);
  final wire = await alice.encrypt(groupId: group, plaintext: utf8.encode('Olá do MLS'));
  final msg = await bob.process(groupId: group, message: wire);
  return '${utf8.decode(msg.plaintext)} (${wire.length} bytes cifrados)';
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('chat_crypto_ffi')),
        body: Center(child: Text(result)),
      ),
    );
  }
}
